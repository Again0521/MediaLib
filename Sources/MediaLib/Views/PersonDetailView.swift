import MediaLibCore
import SwiftUI

struct PersonDetailView: View {
    @EnvironmentObject private var appState: AppState

    let personID: String

    @State private var person: MediaPerson?
    @State private var persistedLibraryCredits: [MediaPersonLibraryCredit] = []
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
                if !libraryItems.isEmpty {
                    detailRow(top: 8, bottom: 8) {
                        mediaSection(
                            title: "库中作品",
                            subtitle: "\(libraryItems.count) 部 · 已穿透全部来源",
                            works: libraryWorks
                        )
                    }
                }
                if !person.knownFor.isEmpty {
                    detailRow(top: 8, bottom: 8) {
                        mediaSection(title: "代表作", subtitle: nil, works: person.knownFor)
                    }
                }
                if !person.filmography.isEmpty {
                    detailRow(top: 8, bottom: 28) {
                        filmographySection(person.filmography)
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
            isLoading = true
            person = await appState.personDetail(personID: personID)
            persistedLibraryCredits = appState.libraryCredits(personID: personID)
            isLoading = false
        }
    }

    private var libraryCredits: [MediaPersonLibraryCredit] {
        persistedLibraryCredits
    }

    private var libraryItems: [MediaItem] {
        guard let person else { return libraryCredits.map(\.media) }
        return appState.libraryItems(
            person: person,
            directCredits: libraryCredits
        )
    }

    private var libraryWorks: [MediaPersonWork] {
        libraryItems.map { item in
            let directRole = libraryCredits.first(where: { $0.media.id == item.id })?.credit.role
            return MediaPersonWork(
                id: item.externalID ?? item.id,
                title: item.title,
                year: item.year,
                role: directRole?.nilIfEmpty ?? matchedFilmographyRole(for: item),
                mediaKind: item.type.rawValue,
                posterURL: item.posterPath,
                popularity: item.rating
            )
        }
    }

    private func matchedFilmographyRole(for item: MediaItem) -> String? {
        guard let person else { return nil }
        return (person.knownFor + person.filmography).first {
            appState.libraryItem(
                matchingExternalID: $0.id,
                title: $0.title,
                year: $0.year
            )?.id == item.id
        }?.role?.nilIfEmpty
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
        .surfaceBackground(cornerRadius: 24)
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

    private func mediaSection(
        title: String,
        subtitle: String?,
        works: [MediaPersonWork]
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSectionHeading(
                title: title,
                subtitle: subtitle,
                systemImage: "film.stack"
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(works.prefix(20))) { work in
                        workCard(work)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
            .verticalScrollPassthroughFromNestedHorizontal()
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: 18)
    }

    private func workCard(_ work: MediaPersonWork) -> some View {
        Button {
            open(work)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                workPoster(work)
                    .frame(width: 112, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(work.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = [work.year.map(String.init), work.role]
                    .compactMap({ $0?.nilIfEmpty }).joined(separator: " · ").nilIfEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 112, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("打开\(work.title)")
    }

    @ViewBuilder
    private func workPoster(_ work: MediaPersonWork) -> some View {
        if let local = localItem(for: work) {
            PosterImage(path: local.posterPath, title: local.title, mediaType: local.type)
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
        } else if let path = work.posterURL, let url = URL(string: path) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
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

    private func filmographySection(_ works: [MediaPersonWork]) -> some View {
        let groups = Dictionary(grouping: works) { $0.mediaKind == "movie" ? "电影" : "电视" }
        return VStack(alignment: .leading, spacing: 16) {
            AppSectionHeading(
                title: "完整履历",
                subtitle: "\(works.count) 项",
                systemImage: "list.bullet.rectangle"
            )
            ForEach(["电影", "电视"], id: \.self) { groupName in
                if let values = groups[groupName], !values.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(groupName)
                            .font(.headline)
                        ForEach(values) { work in
                            Button {
                                open(work)
                            } label: {
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
                                    if localItem(for: work) != nil {
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
                    }
                }
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: 18)
    }

    private func localItem(for work: MediaPersonWork) -> MediaItem? {
        appState.libraryItem(
            matchingExternalID: work.id,
            title: work.title,
            year: work.year
        )
    }

    private func open(_ work: MediaPersonWork) {
        if let local = localItem(for: work) {
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
