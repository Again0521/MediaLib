import MediaLibCore
import SwiftUI

struct MediaTMDBExtrasView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: MediaItem
    let snapshot: MediaDetailSnapshot
    var onOpenArtwork: ([MediaImageViewerEntry], Int) -> Void = { _, _ in }

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailSectionHeader
            if isExpanded {
                detailSections
            }
        }
    }

    private var detailSectionHeader: some View {
        Button {
            withAnimation(reduceMotion ? nil : AppMotion.standard) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("详情")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailSections: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let trailerURL = snapshot.metadata.trailerURL, let url = URL(string: trailerURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("观看预告片", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 14,
                    minHeight: 34,
                    prominent: true
                ))
            }

            if !crewPeople.isEmpty {
                peopleSection(title: "主创", systemImage: "person.badge.key", values: crewPeople)
            }
            if !castPeople.isEmpty {
                peopleSection(title: "演员", systemImage: "person.2", values: castPeople)
            }
            if !snapshot.artwork.isEmpty {
                sectionCard(title: "艺术照", systemImage: "photo.on.rectangle") {
                    artworkStrip
                }
            }
            if !libraryRelated.isEmpty {
                sectionCard(title: "库中相似作品", systemImage: "rectangle.stack.badge.play") {
                    relatedStrip(libraryRelated)
                }
            }
            if !discoveryRelated.isEmpty {
                sectionCard(title: "更多推荐", systemImage: "sparkles") {
                    relatedStrip(discoveryRelated)
                }
            }
            if !relatedLinks.isEmpty {
                sectionCard(title: "相关链接", systemImage: "link") {
                    HStack(spacing: 10) {
                        ForEach(relatedLinks) { link in
                            Button {
                                NSWorkspace.shared.open(link.url)
                            } label: {
                                Label(link.title, systemImage: link.systemImage)
                            }
                            .buttonStyle(LiquidGlassButtonStyle(
                                cornerRadius: 11,
                                horizontalPadding: 13,
                                minHeight: 32
                            ))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var peopleByID: [String: MediaPerson] {
        Dictionary(uniqueKeysWithValues: snapshot.people.map { ($0.id, $0) })
    }

    private var castPeople: [(MediaPerson, MediaCredit)] {
        people(category: "cast")
    }

    private var crewPeople: [(MediaPerson, MediaCredit)] {
        people(category: "crew")
    }

    private func people(category: String) -> [(MediaPerson, MediaCredit)] {
        snapshot.credits
            .filter { $0.category == category }
            .sorted { $0.order < $1.order }
            .compactMap { credit in
                peopleByID[credit.personID].map { ($0, credit) }
            }
    }

    private func peopleSection(
        title: String,
        systemImage: String,
        values: [(MediaPerson, MediaCredit)]
    ) -> some View {
        sectionCard(title: title, systemImage: systemImage) {
            horizontalStrip {
                ForEach(values, id: \.1.id) { person, credit in
                    personCard(person, credit: credit)
                }
            }
        }
    }

    private func personCard(_ person: MediaPerson, credit: MediaCredit) -> some View {
        Button {
            appState.presentPersonDetail(person.id)
        } label: {
            VStack(spacing: 6) {
                avatar(person.profileURL)
                Text(person.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(credit.role)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 88)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("查看\(person.name)的资料和库中作品")
        .accessibilityLabel("\(person.name)，\(credit.role)")
        .accessibilityHint("打开人物详情")
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
        .frame(width: 72, height: 72)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.14 : 0.4), lineWidth: 0.8)
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "person.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var artworkStrip: some View {
        let artwork = snapshot.artwork.sorted { $0.order < $1.order }
        let entries = artwork.map {
            MediaImageViewerEntry(id: $0.id, title: item.title, remoteURL: $0.fullURL)
        }
        return horizontalStrip {
            ForEach(Array(artwork.enumerated()), id: \.element.id) { index, image in
                Button {
                    onOpenArtwork(entries, index)
                } label: {
                    artworkThumbnail(image)
                }
                .buttonStyle(.plain)
                .help(image.kind == "poster" ? "查看海报" : "查看艺术照")
            }
        }
    }

    private func artworkThumbnail(_ image: MediaArtwork) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let isWide = image.aspectRatio >= 1
        return AsyncImage(url: URL(string: image.thumbURL)) { phase in
            switch phase {
            case .success(let value):
                value.resizable().scaledToFill()
            default:
                artworkPlaceholder
            }
        }
        .frame(width: isWide ? 220 : 104, height: isWide ? 124 : 156)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.32), lineWidth: 0.8)
        }
        .overlay(alignment: .bottomLeading) {
            Text(image.kind == "poster" ? "海报" : "剧照")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.48), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
        }
    }

    private var rankedRelated: [MediaRelatedTitle] {
        let currentGenres = genreKeys(for: item)
        return snapshot.relatedTitles.sorted { lhs, rhs in
            if (lhs.localMediaID != nil) != (rhs.localMediaID != nil) {
                return lhs.localMediaID != nil
            }
            return recommendationScore(lhs, currentGenres: currentGenres) >
                recommendationScore(rhs, currentGenres: currentGenres)
        }
    }

    private var libraryRelated: [MediaRelatedTitle] {
        let directlyRecommendedLibraryIDs = Set(rankedRelated.compactMap(\.localMediaID))
        return appState.libraryRecommendations(for: item, snapshot: snapshot)
            .filter { related in
                guard let localMediaID = related.localMediaID else { return false }
                return !directlyRecommendedLibraryIDs.contains(localMediaID)
            }
    }

    private var discoveryRelated: [MediaRelatedTitle] {
        rankedRelated
    }

    private func relatedStrip(_ values: [MediaRelatedTitle]) -> some View {
        horizontalStrip {
            ForEach(values) { related in
                relatedCard(related)
            }
        }
    }

    private func relatedCard(_ related: MediaRelatedTitle) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            if let localID = related.localMediaID,
               let localItem = appState.items.first(where: { $0.id == localID }),
               !(appState.isPrivateItem(localItem) && !appState.canDisplayPrivateItems) {
                appState.presentRelatedDetail(localItem)
            } else if let url = tmdbURL(for: related.externalID) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    relatedPoster(related)
                        .frame(width: 104, height: 156)
                        .clipShape(shape)
                        .overlay {
                            shape.strokeBorder(
                                .white.opacity(colorScheme == .dark ? 0.12 : 0.32),
                                lineWidth: 0.8
                            )
                        }
                    Text(related.localMediaID == nil ? "发现" : "在库")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            (related.localMediaID == nil ? Color.black : AppColors.selectedGlassTint)
                                .opacity(0.78),
                            in: Capsule()
                        )
                        .foregroundStyle(.white)
                        .padding(6)
                }
                Text(related.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let year = related.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 104)
        }
        .buttonStyle(.plain)
        .help(related.localMediaID == nil ? "在 TMDB 查看\(related.title)" : "打开\(related.title)")
    }

    @ViewBuilder
    private func relatedPoster(_ related: MediaRelatedTitle) -> some View {
        if let localID = related.localMediaID,
           let localItem = appState.items.first(where: { $0.id == localID }),
           !(appState.isPrivateItem(localItem) && !appState.canDisplayPrivateItems) {
            PosterImage(path: localItem.posterPath, title: localItem.title, mediaType: localItem.type)
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
        } else if let posterURL = related.posterURL, let url = URL(string: posterURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    relatedPlaceholder
                }
            }
        } else {
            relatedPlaceholder
        }
    }

    private var relatedPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "film")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func recommendationScore(
        _ related: MediaRelatedTitle,
        currentGenres: Set<String>
    ) -> Double {
        var score = related.relation == "recommendation" ? 1.2 : 0.5
        score += min(max(related.rating ?? 0, 0), 10) * 0.12
        score += min(max(related.popularity ?? 0, 0), 100) * 0.006
        if related.localMediaID != nil { score += 4 }
        if let year = related.year, let currentYear = item.year {
            score += max(0, 1.1 - Double(abs(year - currentYear)) / 8)
        }
        if let localID = related.localMediaID,
           let local = appState.items.first(where: { $0.id == localID }) {
            score += Double(currentGenres.intersection(genreKeys(for: local)).count) * 1.1
            if local.favorite { score += 0.5 }
            if local.watchlist { score += 0.6 }
            if local.watched || local.playProgress >= appState.settings.watchedThreshold { score -= 1.7 }
        }
        return score
    }

    private func genreKeys(for value: MediaItem) -> Set<String> {
        guard let genre = value.genre else { return [] }
        return Set(
            genre.components(separatedBy: CharacterSet(charactersIn: ",，、/|;；"))
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .folding(
                            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                            locale: .current
                        )
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )
    }

    private struct RelatedLink: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let url: URL
    }

    private var relatedLinks: [RelatedLink] {
        var values: [RelatedLink] = []
        let query = item.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.title
        if let url = URL(string: "https://search.douban.com/movie/subject_search?search_text=\(query)") {
            values.append(RelatedLink(id: "douban", title: "豆瓣", systemImage: "magnifyingglass", url: url))
        }
        for value in snapshot.externalIDs {
            switch value.provider.lowercased() {
            case "imdb":
                if let url = URL(string: "https://www.imdb.com/title/\(value.value)/") {
                    values.append(RelatedLink(id: "imdb", title: "IMDb", systemImage: "film", url: url))
                }
            case "tmdb":
                let components = value.value.split(separator: ":")
                if components.count == 2,
                   let url = URL(string: "https://www.themoviedb.org/\(components[0])/\(components[1])") {
                    values.append(RelatedLink(id: "tmdb", title: "TMDB", systemImage: "rectangle.stack", url: url))
                }
            default:
                break
            }
        }
        if let url = URL(string: "https://zh.wikipedia.org/w/index.php?search=\(query)") {
            values.append(RelatedLink(id: "wikipedia", title: "维基百科", systemImage: "book", url: url))
        }
        return values
    }

    private func tmdbURL(for externalID: String) -> URL? {
        let parts = externalID.split(separator: ":")
        guard parts.count == 3, parts[0] == "tmdb" else { return nil }
        return URL(string: "https://www.themoviedb.org/\(parts[1])/\(parts[2])")
    }

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
        .verticalScrollPassthroughFromNestedHorizontal()
    }
}
