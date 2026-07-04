import MediaLibCore
import SwiftUI

private enum PersonDetailLayout {
    static let workCardWidth: CGFloat = 112
    static let workPosterAspectRatio: CGFloat = 2.0 / 3.0
    static let workPosterCornerRadius: CGFloat = 11
    static let stripVerticalPadding: CGFloat = 4
    static let workStripHeight: CGFloat = 234
}

struct PersonDetailView: View {
    @EnvironmentObject private var appState: AppState

    let personID: String

    @State private var person: MediaPerson?
    @State private var persistedLibraryCredits: [MediaPersonLibraryCredit] = []
    @State private var libraryWorkRows: [PersonWorkRow] = []
    @State private var knownForRows: [PersonWorkRow] = []
    @State private var filmographyGroups: [PersonFilmographyGroup] = []
    @State private var filmographyTotalCount = 0
    @State private var showsFullFilmography = false
    @State private var isLoading = false

    var body: some View {
        List {
            detailRow(top: 28, bottom: 8) {
                PageHeader(
                    title: "人物",
                    subtitle: person?.knownForDepartment,
                    systemImage: "person.crop.rectangle"
                ) {
                    Button {
                        appState.dismissDetail()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }

            if let person {
                detailRow(top: 8, bottom: 8) {
                    hero(person)
                }
                if !libraryWorkRows.isEmpty {
                    detailRow(top: 8, bottom: 8) {
                        mediaSection(
                            title: "库中作品",
                            subtitle: "\(libraryWorkRows.count) 部 · 已穿透全部来源",
                            rows: libraryWorkRows
                        )
                    }
                }
                if !knownForRows.isEmpty {
                    detailRow(top: 8, bottom: 8) {
                        mediaSection(title: "代表作", subtitle: nil, rows: knownForRows)
                    }
                }
                if !filmographyGroups.isEmpty {
                    detailRow(top: 8, bottom: 28) {
                        filmographySection()
                    }
                }
            } else if isLoading {
                detailRow(top: 24, bottom: 24) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在获取人物资料与作品履历…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                detailRow(top: 24, bottom: 24) {
                    EmptyStateView(
                        title: "暂无人物资料",
                        systemImage: "person.crop.circle.badge.questionmark",
                        message: "当前来源只提供了人物名称。配置 TMDB 后可继续补充简介和作品履历。"
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
        .background(AppPageBackground())
        .frame(minWidth: 820, minHeight: 620)
        .task(id: personID) {
            resetPresentation()
            isLoading = true
            if let cached = appState.cachedPersonDetail(personID: personID) {
                person = cached
                isLoading = false
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            let loadedPerson = await appState.personDetail(personID: personID)
            guard !Task.isCancelled else { return }
            if let loadedPerson {
                person = loadedPerson
                isLoading = false
            } else if person == nil {
                isLoading = false
            }
            await Task.yield()
            guard !Task.isCancelled, let visiblePerson = person else { return }
            let credits = appState.libraryCredits(personID: personID)
            let items = appState.libraryItems(person: visiblePerson, directCredits: credits)
            persistedLibraryCredits = credits
            applyPresentation(person: visiblePerson, items: items, credits: credits)
            showsFullFilmography = false
            isLoading = false
        }
    }

    private var libraryCredits: [MediaPersonLibraryCredit] {
        persistedLibraryCredits
    }

    private func resetPresentation() {
        person = nil
        persistedLibraryCredits = []
        libraryWorkRows = []
        knownForRows = []
        filmographyGroups = []
        filmographyTotalCount = 0
        showsFullFilmography = false
    }

    private func applyPresentation(
        person: MediaPerson,
        items: [MediaItem],
        credits: [MediaPersonLibraryCredit]
    ) {
        let libraryRows = items.map { item in
            let directRole = credits.first(where: { $0.media.id == item.id })?.credit.role
            let work = MediaPersonWork(
                    id: item.externalID ?? item.id,
                    title: item.title,
                    year: item.year,
                    role: directRole?.nilIfEmpty ?? matchedFilmographyRole(for: item, person: person),
                    mediaKind: item.type.rawValue,
                    posterURL: item.posterPath,
                    popularity: item.rating
                )
            return PersonWorkRow(work: work, localItem: item)
        }
        libraryWorkRows = libraryRows
        knownForRows = person.knownFor.map { work in
            PersonWorkRow(work: work, localItem: localItem(for: work))
        }
        filmographyTotalCount = person.filmography.count
        filmographyGroups = ["电影", "电视"].compactMap { groupName in
            let values = person.filmography
                .filter { ($0.mediaKind == "movie" ? "电影" : "电视") == groupName }
                .map { work in PersonWorkRow(work: work, localItem: localItem(for: work)) }
            guard !values.isEmpty else { return nil }
            return PersonFilmographyGroup(title: groupName, rows: values)
        }
    }

    private func matchedFilmographyRole(for item: MediaItem, person: MediaPerson) -> String? {
        return (person.knownFor + person.filmography).first {
            appState.libraryItem(
                matchingExternalID: $0.id,
                title: $0.title,
                year: $0.year
            )?.id == item.id
        }?.role?.nilIfEmpty
    }

    private func localItem(for work: MediaPersonWork) -> MediaItem? {
        appState.libraryItem(
            matchingExternalID: work.id,
            title: work.title,
            year: work.year
        )
    }

    private func mediaSection(
        title: String,
        subtitle: String?,
        rows: [PersonWorkRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeading(
                title: title,
                subtitle: subtitle,
                systemImage: "film.stack"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(rows.prefix(20))) { row in
                        workCard(row)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, PersonDetailLayout.stripVerticalPadding)
                .frame(height: PersonDetailLayout.workStripHeight, alignment: .top)
            }
            .frame(height: PersonDetailLayout.workStripHeight)
            .verticalScrollPassthroughFromNestedHorizontal()
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: 18)
    }

    private func hero(_ person: MediaPerson) -> some View {
        HStack(alignment: .top, spacing: 24) {
            personAvatar(person)
                .frame(width: 180, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.34), lineWidth: 0.85)
                }

            VStack(alignment: .leading, spacing: 14) {
                Text(person.name)
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(2)

                DetailPersonMetadataFlow {
                    if let department = person.knownForDepartment, !department.isEmpty {
                        DetailPersonMetadataChip(title: localizedDepartment(department), systemImage: "person.text.rectangle")
                    }
                    if let birthday = person.birthday, !birthday.isEmpty {
                        DetailPersonMetadataChip(title: birthday, systemImage: "birthday.cake")
                    }
                    if let place = person.placeOfBirth, !place.isEmpty {
                        DetailPersonMetadataChip(title: place, systemImage: "mappin.and.ellipse")
                    }
                }

                Text(person.biography?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "暂无人物简介。")
                    .foregroundStyle(.secondary)
                    .lineLimit(12)

                HStack(spacing: 10) {
                    ForEach(personLinks(person)) { link in
                        Button {
                            NSWorkspace.shared.open(link.url)
                        } label: {
                            Label(link.title, systemImage: link.systemImage)
                        }
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 12, minHeight: 32))
            }
        }
        .padding(18)
        .staticSurfaceBackground(cornerRadius: 24, thickness: 1.3)
        .repeatedCardChrome(false, cornerRadius: 24)
    }

    @ViewBuilder
    private func personAvatar(_ person: MediaPerson) -> some View {
        if let profileURL = person.profileURL, let url = URL(string: profileURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    personPlaceholder
                }
            }
        } else {
            personPlaceholder
        }
    }

    private var personPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "person.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
        }
    }

    private func workCard(_ row: PersonWorkRow) -> some View {
        let work = row.work
        return Button {
            open(row)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                workPoster(row)
                    .aspectRatio(PersonDetailLayout.workPosterAspectRatio, contentMode: .fit)
                    .frame(width: PersonDetailLayout.workCardWidth)
                    .background(AppColors.cleanPanelFill)
                    .clipShape(RoundedRectangle(cornerRadius: PersonDetailLayout.workPosterCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PersonDetailLayout.workPosterCornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)
                    }
                Text(work.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = [work.year.map(String.init), work.role]
                    .compactMap({ $0?.nilIfEmpty }).joined(separator: " · ").nilIfEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: PersonDetailLayout.workCardWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("打开\(work.title)")
    }

    @ViewBuilder
    private func workPoster(_ row: PersonWorkRow) -> some View {
        let work = row.work
        if let local = row.localItem {
            PosterImage(path: local.posterPath, title: local.title, mediaType: local.type, contentMode: .fit)
        } else if let path = work.posterURL, let url = URL(string: path) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    workPlaceholder
                }
            }
        } else {
            workPlaceholder
        }
    }

    private var workPlaceholder: some View {
        ZStack {
            AppColors.cleanPanelFill
            Image(systemName: "film")
                .foregroundStyle(.secondary)
        }
    }

    private func filmographySection() -> some View {
        let visibleLimitPerGroup = showsFullFilmography ? Int.max : 40
        let visibleCount = filmographyGroups.reduce(0) { total, group in
            total + min(group.rows.count, visibleLimitPerGroup)
        }
        return VStack(alignment: .leading, spacing: 16) {
            AppSectionHeading(
                title: "完整履历",
                subtitle: showsFullFilmography || visibleCount >= filmographyTotalCount
                    ? "\(filmographyTotalCount) 项"
                    : "先显示 \(visibleCount)/\(filmographyTotalCount) 项",
                systemImage: "list.bullet.rectangle"
            )
            ForEach(filmographyGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.headline)
                    ForEach(Array(group.rows.prefix(visibleLimitPerGroup))) { row in
                        Button {
                            open(row)
                        } label: {
                            let work = row.work
                            HStack(spacing: 12) {
                                Text(work.year.map(String.init) ?? "—")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .leading)
                                Text(work.title)
                                    .foregroundStyle(.primary)
                                if let role = work.role, !role.isEmpty {
                                    Text(role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if row.localItem != nil {
                                    Text("在库")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(AppColors.selectedGlassTint)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if group.rows.count > visibleLimitPerGroup {
                        Button {
                            withAnimation(AppMotion.standard) {
                                showsFullFilmography = true
                            }
                        } label: {
                            Label("展开全部 \(group.rows.count) 项\(group.title)履历", systemImage: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 28))
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: 18)
    }

    private func open(_ row: PersonWorkRow) {
        let work = row.work
        if let local = row.localItem {
            appState.presentRelatedDetail(local)
            return
        }
        let parts = work.id.split(separator: ":")
        guard parts.count == 3, parts[0] == "tmdb",
              let url = URL(string: "https://www.themoviedb.org/\(parts[1])/\(parts[2])") else { return }
        NSWorkspace.shared.open(url)
    }

    private func localizedDepartment(_ value: String) -> String {
        switch value.lowercased() {
        case "acting": return "演员"
        case "directing": return "导演"
        case "writing": return "编剧"
        case "production": return "制片"
        default: return value
        }
    }

    private struct PersonLink: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let url: URL
    }

    private func personLinks(_ person: MediaPerson) -> [PersonLink] {
        person.externalIDs.compactMap { value in
            switch value.provider.lowercased() {
            case "tmdb":
                return URL(string: "https://www.themoviedb.org/person/\(value.value)").map {
                    PersonLink(id: "tmdb", title: "TMDB", systemImage: "person.text.rectangle", url: $0)
                }
            case "imdb":
                return URL(string: "https://www.imdb.com/name/\(value.value)/").map {
                    PersonLink(id: "imdb", title: "IMDb", systemImage: "film", url: $0)
                }
            default:
                return nil
            }
        }
    }

    private func detailRow<Content: View>(
        top: CGFloat,
        bottom: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .listRowInsets(EdgeInsets(
                top: top,
                leading: AppSpacing.pageHorizontal,
                bottom: bottom,
                trailing: AppSpacing.pageHorizontal
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct PersonWorkRow: Identifiable {
    let work: MediaPersonWork
    let localItem: MediaItem?

    var id: String {
        [
            work.id,
            work.title,
            work.year.map(String.init) ?? "",
            localItem?.id ?? ""
        ].joined(separator: "|")
    }
}

private struct PersonFilmographyGroup: Identifiable {
    let title: String
    let rows: [PersonWorkRow]

    var id: String { title }
}

private struct DetailPersonMetadataFlow<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        PosterBadgeFlowLayout(horizontalSpacing: 8, verticalSpacing: 7) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailPersonMetadataChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AppColors.cleanFieldFill.opacity(0.72), in: Capsule())
            .overlay {
                Capsule().strokeBorder(AppColors.cleanPanelBorder.opacity(0.82), lineWidth: 0.75)
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
