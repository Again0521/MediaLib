import MediaLibCore
import SwiftUI

private enum MusicTagScope: String, CaseIterable, Identifiable {
    case unmatched
    case all
    case missingArtwork
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unmatched: return "未匹配"
        case .all: return "全部音乐"
        case .missingArtwork: return "缺少封面"
        case .favorites: return "收藏"
        }
    }

    var systemImage: String {
        switch self {
        case .unmatched: return "questionmark.circle"
        case .all: return "music.note.list"
        case .missingArtwork: return "photo"
        case .favorites: return "heart"
        }
    }
}

private enum MusicTagCandidateStatus: Hashable {
    case ready
    case matched
    case noMatch
    case applied
    case written
    case failed(String)

    var title: String {
        switch self {
        case .ready: return "待匹配"
        case .matched: return "已匹配"
        case .noMatch: return "未找到"
        case .applied: return "已更新库"
        case .written: return "已写入文件"
        case .failed: return "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "circle.dotted"
        case .matched: return "sparkles"
        case .noMatch: return "magnifyingglass"
        case .applied: return "checkmark.circle"
        case .written: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .secondary
        case .matched: return .accentColor
        case .noMatch: return .orange
        case .applied, .written: return .green
        case .failed: return .red
        }
    }

    var detail: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }
}

private struct MusicTagCandidate: Identifiable, Hashable {
    var id: String { item.id }
    var item: MediaItem
    var draft: MusicTagDraft
    var query: String
    var selected: Bool
    var expanded = false
    var status: MusicTagCandidateStatus
    var note: String?
}

struct MusicTagScraperSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let autoStart: Bool

    @State private var scope: MusicTagScope
    @State private var queryText = ""
    @State private var writeFileTags = false
    @State private var includeLyrics: Bool
    @State private var candidates: [MusicTagCandidate] = []
    @State private var isMatching = false
    @State private var isApplying = false
    @State private var progressText = "准备匹配音乐元数据"
    @State private var workTask: Task<Void, Never>?
    @State private var didHandleAutoStart = false

    init(
        autoStart: Bool = false,
        includeLyrics: Bool = false
    ) {
        self.autoStart = autoStart
        _scope = State(initialValue: .unmatched)
        _includeLyrics = State(initialValue: includeLyrics)
    }

    private var isWorking: Bool {
        isMatching || isApplying
    }

    private var scopedTracks: [MediaItem] {
        let base: [MediaItem]
        switch scope {
        case .unmatched:
            base = appState.musicTracks.filter { ($0.artist?.isEmpty ?? true) || ($0.album?.isEmpty ?? true) || $0.metadataProvider == nil }
        case .all:
            base = appState.musicTracks
        case .missingArtwork:
            base = appState.musicTracks.filter { ($0.posterPath?.isEmpty ?? true) || $0.posterPath?.hasSuffix("-default.jpg") == true }
        case .favorites:
            base = appState.musicTracks.filter(\.favorite)
        }
        let search = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(search) ||
            ($0.artist?.localizedCaseInsensitiveContains(search) ?? false) ||
            ($0.album?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var selectedCount: Int {
        candidates.filter(\.selected).count
    }

    private var matchedCount: Int {
        candidates.filter {
            if case .matched = $0.status { return true }
            return false
        }.count
    }

    private var bodySubtitle: String {
        if candidates.isEmpty {
            return "\(scopedTracks.count) 首可处理 · \(appState.settings.musicMetadataProvider.displayName)"
        }
        return "\(matchedCount)/\(candidates.count) 首已匹配 · 已选择 \(selectedCount) 首"
    }

    var body: some View {
        ZStack {
            AppPageBackground()

            VStack(alignment: .leading, spacing: 16) {
                header
                controlDeck
                resultsArea
                footer
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .frame(minWidth: 720, idealWidth: 1040, maxWidth: 1240, minHeight: 560, idealHeight: 800, maxHeight: 920)
        .onAppear {
            guard autoStart, !didHandleAutoStart else { return }
            didHandleAutoStart = true
            startMatching()
        }
        .onDisappear {
            workTask?.cancel()
        }
    }

    private var header: some View {
        PageHeader(
            title: "音乐元数据获取",
            subtitle: bodySubtitle,
            systemImage: "tag"
        ) {
            Button {
                workTask?.cancel()
                dismiss()
            } label: {
                Label("关闭", systemImage: "xmark")
            }
        }
    }

    private var controlDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    scopePicker
                    metadataSearchField.frame(width: 240)
                    Spacer()
                    metadataToggleGroup
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        scopePicker
                        Spacer()
                        metadataToggleGroup
                    }
                    metadataSearchField
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 10) {
                Label(progressText, systemImage: isWorking ? "hourglass" : "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button {
                    selectAll(true)
                } label: {
                    Label("全选", systemImage: "checkmark.circle")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 10, minHeight: 30))
                .disabled(candidates.isEmpty || isWorking)

                Button {
                    selectAll(false)
                } label: {
                    Label("清空", systemImage: "circle")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 10, minHeight: 30))
                .disabled(candidates.isEmpty || isWorking)

                Button {
                    startMatching()
                } label: {
                    Label(isMatching ? "匹配中" : "开始匹配", systemImage: "sparkles")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(isWorking || scopedTracks.isEmpty || appState.settings.musicMetadataProvider == .disabled)
            }
        }
        .padding(14)
        .staticSurfaceBackground(cornerRadius: 18, thickness: 1.06)
    }

    private var scopePicker: some View {
        HStack(spacing: 7) {
            ForEach(MusicTagScope.allCases) { tagScope in
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.fast) {
                        scope = tagScope
                        candidates = []
                        progressText = "准备匹配音乐元数据"
                    }
                } label: {
                    GlassCapsuleControl(isSelected: scope == tagScope, height: 30, horizontalPadding: 10) {
                        Label(tagScope.title, systemImage: tagScope.systemImage)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.92)
    }

    private var metadataSearchField: some View {
        GlassSearchField(placeholder: "过滤歌曲", text: $queryText, thickness: 1.02, minWidth: 150, maxWidth: 220)
    }

    private var metadataToggleGroup: some View {
        HStack(spacing: 8) {
            MusicTagToggleChip(title: "歌词", systemImage: "text.quote", isOn: $includeLyrics)
            MusicTagToggleChip(title: "写入文件", systemImage: "square.and.pencil", isOn: $writeFileTags)
        }
    }

    private var resultsArea: some View {
        Group {
            if candidates.isEmpty {
                MusicTagEmptyPanel(
                    trackCount: scopedTracks.count,
                    providerName: appState.settings.musicMetadataProvider.displayName,
                    writeFileTags: writeFileTags
                )
            } else {
                // 滚动抽搐修复：原生 List(NSTableView) 对这种含图片/可编辑草稿的高行做整表布局，滚动时反复重算行高→抖动。
                // 改为 ScrollView + LazyVStack（本项目已在队列弹层、海报墙用同款方案），按需懒加载、行高稳定、滚动顺滑。
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach($candidates) { $candidate in
                            MusicTagCandidateRow(
                                candidate: $candidate,
                                writeFileTags: writeFileTags,
                                canWriteFileTags: appState.canWriteMusicFileTags(for: candidate.item)
                            )
                            .padding(.horizontal, 3)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
                .suppressHoverEffectsDuringScroll()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if writeFileTags {
                Label("写入会修改本地音频文件；远程或不支持格式会逐条跳过并显示失败原因。", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Label("默认只更新 MediaLIB 索引；打开“写入文件”后才会改动音乐文件标签。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isWorking {
                Button {
                    workTask?.cancel()
                } label: {
                    Label("停止", systemImage: "stop.circle")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 34))
            }

            Button {
                applySelected()
            } label: {
                Label(writeFileTags ? "写入所选" : "更新所选", systemImage: writeFileTags ? "square.and.arrow.down" : "checkmark.seal")
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 13, horizontalPadding: 16, minHeight: 36, prominent: true))
            .disabled(isWorking || selectedCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .staticSurfaceBackground(cornerRadius: 17, thickness: 1.02)
    }

    private func selectAll(_ selected: Bool) {
        for index in candidates.indices {
            candidates[index].selected = selected
        }
    }

    private func startMatching() {
        workTask?.cancel()
        workTask = Task { @MainActor in
            await matchTracks()
        }
    }

    @MainActor
    private func matchTracks() async {
        guard appState.settings.musicMetadataProvider != .disabled else {
            appState.alert = AppAlert(title: "音乐数据源未启用", message: "可在设置中选择 MusicBrainz 或 iTunes Search。")
            return
        }

        let tracks = scopedTracks
        guard !tracks.isEmpty else {
            progressText = "没有符合当前范围的歌曲"
            return
        }

        isMatching = true
        candidates = []
        progressText = "准备匹配 \(tracks.count) 首"
        defer { isMatching = false }

        let service = MetadataSearchService()
        for (index, track) in tracks.enumerated() {
            if Task.isCancelled {
                progressText = "已停止，保留 \(candidates.count) 条结果"
                break
            }

            let query = query(for: track)
            progressText = "\(index + 1)/\(tracks.count) \(track.title)"
            do {
                if let result = try await service.searchMusic(query: query, provider: appState.settings.musicMetadataProvider, lastfmAPIKey: appState.settings.lastfmAPIKey).first {
                    let update = await service.materializedMetadataUpdate(
                        for: result,
                        itemID: track.id,
                        artworkDirectory: appState.directories?.thumbnails,
                        preserveEmbeddedPoster: track.hasEmbeddedArtwork
                    )
                    let lyrics = includeLyrics ? await fetchLyrics(for: update, fallbackTrack: track) : nil
                    let draft = MusicTagDraft(
                        title: update.title,
                        artist: update.artist,
                        album: update.album,
                        trackNumber: update.trackNumber,
                        year: update.year,
                        lyrics: lyrics,
                        artworkPath: update.posterPath ?? track.posterPath,
                        externalID: update.externalID,
                        metadataProvider: update.metadataProvider
                    )
                    candidates.append(
                        MusicTagCandidate(
                            item: track,
                            draft: draft,
                            query: query,
                            selected: true,
                            status: .matched,
                            note: result.subtitle
                        )
                    )
                } else {
                    candidates.append(
                        MusicTagCandidate(
                            item: track,
                            draft: MusicTagDraft(item: track),
                            query: query,
                            selected: false,
                            status: .noMatch,
                            note: "可展开后手动编辑标签"
                        )
                    )
                }
            } catch {
                candidates.append(
                    MusicTagCandidate(
                        item: track,
                        draft: MusicTagDraft(item: track),
                        query: query,
                        selected: false,
                        status: .failed(error.localizedDescription),
                        note: "查询：\(query)"
                    )
                )
            }
        }

        if !Task.isCancelled {
            progressText = "完成 \(matchedCount)/\(tracks.count) 首匹配"
        }
    }

    private func applySelected() {
        workTask?.cancel()
        workTask = Task { @MainActor in
            await applySelectedCandidates()
        }
    }

    @MainActor
    private func applySelectedCandidates() async {
        let selectedIDs = candidates.filter(\.selected).map(\.id)
        guard !selectedIDs.isEmpty else { return }
        isApplying = true
        progressText = "准备写入 \(selectedIDs.count) 首"
        defer { isApplying = false }

        var successCount = 0
        for (offset, id) in selectedIDs.enumerated() {
            if Task.isCancelled {
                progressText = "已停止，完成 \(successCount)/\(selectedIDs.count) 首"
                break
            }
            guard let index = candidates.firstIndex(where: { $0.id == id }) else { continue }
            let candidate = candidates[index]
            progressText = "\(offset + 1)/\(selectedIDs.count) \(candidate.item.title)"

            do {
                let report = try await appState.applyMusicTagDraft(
                    candidate.draft,
                    to: candidate.item,
                    writeFileTags: writeFileTags
                )
                successCount += 1
                candidates[index].selected = false
                candidates[index].status = report.didWriteFile ? .written : .applied
                candidates[index].note = report.warning ?? candidates[index].note
            } catch {
                candidates[index].status = .failed(error.localizedDescription)
                candidates[index].note = error.localizedDescription
            }
        }

        if !Task.isCancelled {
            progressText = "完成 \(successCount)/\(selectedIDs.count) 首"
        }
    }

    private func query(for track: MediaItem) -> String {
        let parts = [track.artist, track.album, track.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? track.title : parts.joined(separator: " ")
    }

    private func fetchLyrics(for update: MediaMetadataUpdate, fallbackTrack: MediaItem) async -> String? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: update.title ?? fallbackTrack.title),
            URLQueryItem(name: "artist_name", value: update.artist ?? fallbackTrack.artist),
            URLQueryItem(name: "album_name", value: update.album ?? fallbackTrack.album)
        ].filter { $0.value?.isEmpty == false }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("MediaLIB/1.0 local macOS media library", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([MusicTagLyricsSearchResult].self, from: data),
              let text = results.first.flatMap({ $0.syncedLyrics ?? $0.plainLyrics })?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}

private struct MusicTagToggleChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(AppMotion.fast) {
                isOn.toggle()
            }
        } label: {
            GlassCapsuleControl(isSelected: isOn, height: 30, horizontalPadding: 10) {
                Label(title, systemImage: systemImage)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MusicTagEmptyPanel: View {
    let trackCount: Int
    let providerName: String
    let writeFileTags: Bool

    var body: some View {
        VStack(spacing: 18) {
            PlayfulSymbolIcon(systemImage: "tag", size: 62)
            VStack(spacing: 6) {
                Text(trackCount == 0 ? "没有可处理的歌曲" : "选择范围后开始匹配")
                    .font(.title3.weight(.semibold))
                Text("当前数据源：\(providerName) · \(writeFileTags ? "将写入音频文件" : "仅更新媒体库索引")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .staticSurfaceBackground(cornerRadius: 22, thickness: 1.08)
    }
}

private struct MusicTagCandidateRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var candidate: MusicTagCandidate
    let writeFileTags: Bool
    let canWriteFileTags: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.fast) {
                        candidate.selected.toggle()
                    }
                } label: {
                    Image(systemName: candidate.selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(candidate.selected ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)

                PosterImage(path: candidate.draft.artworkPath ?? candidate.item.posterPath, title: candidate.draft.title ?? candidate.item.title, mediaType: .music)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.58), lineWidth: 0.8)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.draft.title ?? candidate.item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(proposedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("原始：\(candidate.item.title)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if writeFileTags && !canWriteFileTags {
                    Label("不可写", systemImage: "lock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .staticSurfaceBackground(cornerRadius: 13, thickness: 0.88)
                }

                MusicTagStatusPill(status: candidate.status)

                Button {
                    withAnimation(reduceMotion ? nil : AppMotion.fast) {
                        candidate.expanded.toggle()
                    }
                } label: {
                    Image(systemName: candidate.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 0, minHeight: 28, thickness: 0.94))
            }

            if let detail = candidate.status.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.leading, 36)
            } else if let note = candidate.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 36)
            }

            if candidate.expanded {
                MusicTagDraftEditor(draft: $candidate.draft)
                    .padding(.leading, 36)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .staticSurfaceBackground(selected: candidate.selected, cornerRadius: 18, thickness: candidate.selected ? 1.18 : 1.02)
        .pointerLiquidEdge(cornerRadius: 18, intensity: candidate.selected ? 1.02 : 0.72)
    }

    private var proposedLine: String {
        let parts = [candidate.draft.artist, candidate.draft.album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let suffix = candidate.draft.year.map { " · \($0)" } ?? ""
        return (parts.isEmpty ? "未知艺术家 · 未知专辑" : parts.joined(separator: " · ")) + suffix
    }
}

private struct MusicTagStatusPill: View {
    let status: MusicTagCandidateStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .staticSurfaceBackground(cornerRadius: 14, thickness: 0.9)
    }
}

private struct MusicTagDraftEditor: View {
    @Binding var draft: MusicTagDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MusicTagField(title: "标题", text: textBinding(\.title))
                MusicTagField(title: "艺术家", text: textBinding(\.artist))
                MusicTagField(title: "专辑", text: textBinding(\.album))
            }
            HStack(spacing: 10) {
                MusicTagField(title: "曲序", text: intBinding(\.trackNumber), width: 96)
                MusicTagField(title: "年份", text: intBinding(\.year), width: 112)
                MusicTagField(title: "封面路径", text: textBinding(\.artworkPath))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("歌词标签")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: textBinding(\.lyrics))
                    .font(.caption)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 76, maxHeight: 112)
                    .staticSurfaceBackground(cornerRadius: 11, thickness: 0.9)
            }
        }
        .padding(12)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.94)
    }

    private func textBinding(_ keyPath: WritableKeyPath<MusicTagDraft, String?>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath] ?? ""
        } set: { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            draft[keyPath: keyPath] = cleaned.isEmpty ? nil : cleaned
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<MusicTagDraft, Int?>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath].map(String.init) ?? ""
        } set: { value in
            let cleaned = value.filter(\.isNumber)
            draft[keyPath: keyPath] = cleaned.isEmpty ? nil : Int(cleaned)
        }
    }
}

private struct MusicTagField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat?

    init(title: String, text: Binding<String>, width: CGFloat? = nil) {
        self.title = title
        self._text = text
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .glassFormField(cornerRadius: 10, thickness: 0.96)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

private struct MusicTagLyricsSearchResult: Decodable {
    var plainLyrics: String?
    var syncedLyrics: String?
}
