import MediaLibCore
import SwiftUI

private struct SimilarDisplayItem: Identifiable {
    let id: String
    let similar: TMDBSimilarTitle
    let localItem: MediaItem?
    let score: Double
}

/// 详情页内容深度区：演职人员（A1）+ 相关推荐（A2）。
/// 对已匹配 TMDB 的影视条目，进详情时按需拉取 credits + similar 展示；相关推荐与本地库交叉匹配，
/// 已入库的可点开，未入库的作为"发现"展示。
struct MediaTMDBExtrasView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let item: MediaItem

    @State private var enrichment: TMDBEnrichment?
    @State private var isLoading = false
    @State private var loadedItemID: String?

    private var canEnrich: Bool {
        item.type != .music && (item.externalID?.hasPrefix("tmdb:") == true)
    }

    var body: some View {
        Group {
            if canEnrich, let enrichment {
                VStack(alignment: .leading, spacing: 20) {
                    if let trailerURL = enrichment.trailerURL, let url = URL(string: trailerURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("观看预告片", systemImage: "play.rectangle.fill")
                        }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 34, prominent: true))
                        .help("在浏览器打开 YouTube 预告片")
                    }
                    let people = enrichment.crew + enrichment.cast
                    if !people.isEmpty {
                        sectionCard(title: "演职人员", systemImage: "person.2") {
                            horizontalStrip {
                                ForEach(people) { personCard($0) }
                            }
                        }
                    }
                    if !enrichment.similar.isEmpty {
                        sectionCard(title: "相关推荐", systemImage: "sparkles") {
                            similarStrip(enrichment.similar)
                        }
                    }
                }
            } else if canEnrich, isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在获取演职人员与相关推荐…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: item.id) { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard canEnrich, loadedItemID != item.id else { return }
        loadedItemID = item.id
        enrichment = nil
        isLoading = true
        defer { isLoading = false }
        let service = TMDBEnrichmentService()
        enrichment = try? await service.fetch(
            externalID: item.externalID ?? "",
            apiKey: appState.settings.tmdbAPIKey,
            language: appState.settings.tmdbLanguage
        )
    }

    // MARK: - 容器

    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 18)
    }

    private func horizontalStrip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                content()
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
        }
    }

    // MARK: - 演职人员

    private func personCard(_ person: TMDBPerson) -> some View {
        VStack(spacing: 6) {
            avatar(person.profileURL)
            Text(person.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(person.role)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 84)
    }

    private func avatar(_ url: String?) -> some View {
        let shape = Circle()
        return Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 70, height: 70)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.4), lineWidth: 0.8) }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "person.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 相关推荐

    private func similarStrip(_ similar: [TMDBSimilarTitle]) -> some View {
        let localByExternalID: [String: MediaItem] = Dictionary(
            appState.items.compactMap { item in
                guard !(appState.isPrivateItem(item) && !appState.canDisplayPrivateItems) else { return nil }
                return item.externalID.map { ($0, item) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let currentGenres = Set(genreKeys(for: item))
        let ranked = similar.enumerated()
            .map { index, sim in
                let localItem = localByExternalID[sim.id]
                return SimilarDisplayItem(
                    id: sim.id,
                    similar: sim,
                    localItem: localItem,
                    score: similarRecommendationScore(
                        sim,
                        index: index,
                        localItem: localItem,
                        currentGenres: currentGenres
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.similar.title.localizedCaseInsensitiveCompare(rhs.similar.title) == .orderedAscending
            }
        return horizontalStrip {
            ForEach(ranked) { entry in
                similarCard(entry.similar, localItem: entry.localItem)
            }
        }
    }

    private func similarRecommendationScore(
        _ sim: TMDBSimilarTitle,
        index: Int,
        localItem: MediaItem?,
        currentGenres: Set<String>
    ) -> Double {
        var score = Double(max(0, 16 - index)) * 0.08
        if let year = sim.year, let currentYear = item.year {
            score += max(0, 1.2 - Double(abs(year - currentYear)) / 8)
        }

        guard let localItem else { return score }
        score += 3.6
        score += normalizedProviderScore(localItem.rating) * 0.9
        score += normalizedUserScore(localItem.userRating) * 0.75
        score += seriesRecommendationTypes.contains(localItem.type) ? 0.8 : 0.2
        score += localItem.watchlist ? 0.7 : 0
        score += localItem.favorite ? 0.45 : 0
        let overlap = currentGenres.intersection(genreKeys(for: localItem)).count
        score += min(Double(overlap), 3) * 1.15
        if localItem.watched || localItem.playProgress >= appState.settings.watchedThreshold {
            score -= 1.8
        } else if localItem.playProgress <= 0.02 {
            score += 0.5
        }
        return score
    }

    private var seriesRecommendationTypes: Set<MediaType> {
        [.tvShow, .anime, .documentary, .variety]
    }

    private func normalizedProviderScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return rating <= 5 ? rating * 2 : min(rating, 10)
    }

    private func normalizedUserScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return min(rating, 5) * 2
    }

    private func genreKeys(for item: MediaItem) -> Set<String> {
        guard let genre = item.genre else { return [] }
        let separators = CharacterSet(charactersIn: ",，、/|;；")
        return Set(
            genre
                .components(separatedBy: separators)
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )
    }

    private func similarCard(_ sim: TMDBSimilarTitle, localItem: MediaItem?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            if let localItem { appState.selectedItem = localItem }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    poster(sim: sim, localItem: localItem)
                        .frame(width: 104, height: 156)
                        .clipShape(shape)
                        .overlay { shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.32), lineWidth: 0.8) }

                    Text(localItem != nil ? "在库" : "未入库")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((localItem != nil ? AppColors.selectedGlassTint : Color.black).opacity(localItem != nil ? 0.92 : 0.5), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
                Text(sim.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let year = sim.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 104)
            .opacity(localItem != nil ? 1 : 0.84)
        }
        .buttonStyle(.plain)
        .disabled(localItem == nil)
        .help(localItem != nil ? "打开\(sim.title)" : "尚未入库")
    }

    @ViewBuilder
    private func poster(sim: TMDBSimilarTitle, localItem: MediaItem?) -> some View {
        if let localItem {
            PosterImage(path: localItem.posterPath, title: localItem.title, mediaType: localItem.type)
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
        } else if let url = sim.posterURL, let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "film")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
