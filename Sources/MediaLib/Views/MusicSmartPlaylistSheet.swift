import MediaLibCore
import SwiftUI

struct MusicSmartPlaylistEditorRequest: Identifiable {
    let playlist: MusicSmartPlaylist
    let isNew: Bool

    var id: String { playlist.id }

    static func create() -> MusicSmartPlaylistEditorRequest {
        MusicSmartPlaylistEditorRequest(playlist: MusicSmartPlaylist(name: "新建智能歌单"), isNew: true)
    }

    static func edit(_ playlist: MusicSmartPlaylist) -> MusicSmartPlaylistEditorRequest {
        MusicSmartPlaylistEditorRequest(playlist: playlist, isNew: false)
    }
}

struct MusicSmartPlaylistSheet: View {
    let request: MusicSmartPlaylistEditorRequest
    let onSave: (MusicSmartPlaylist) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var filter: MusicSmartPlaylistFilter
    @State private var recency: MusicSmartPlaylistRecency
    @State private var sort: MusicSmartPlaylistSort
    @State private var limit: MusicSmartPlaylistLimit

    private let controlWidth: CGFloat = 300

    init(
        request: MusicSmartPlaylistEditorRequest,
        onSave: @escaping (MusicSmartPlaylist) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: request.playlist.name)
        _filter = State(initialValue: request.playlist.filter)
        _recency = State(initialValue: request.playlist.recency)
        _sort = State(initialValue: request.playlist.sort)
        _limit = State(initialValue: request.playlist.limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: request.isNew ? "新建智能歌单" : "编辑智能歌单",
                subtitle: "保存筛选与排序规则，曲目随音乐库自动更新。",
                systemImage: "music.note.list"
            )

            VStack(spacing: 14) {
                SettingsRow(title: "名称", systemImage: "pencil.line") {
                    TextField("智能歌单", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .glassFormField()
                        .frame(width: Self.optionMenuWidth, alignment: .trailing)
                }
                SettingsRow(title: "筛选条件", systemImage: "line.3.horizontal.decrease.circle") {
                    picker(selection: $filter, selectedTitle: filter.displayName) {
                        ForEach(MusicSmartPlaylistFilter.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
                SettingsRow(title: "加入时间", systemImage: "calendar.badge.clock") {
                    picker(selection: $recency, selectedTitle: recency.displayName) {
                        ForEach(MusicSmartPlaylistRecency.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
                SettingsRow(title: "排序方式", systemImage: "arrow.up.arrow.down") {
                    picker(selection: $sort, selectedTitle: sort.displayName) {
                        ForEach(MusicSmartPlaylistSort.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
                SettingsRow(title: "数量上限", systemImage: "number") {
                    picker(selection: $limit, selectedTitle: limit.displayName) {
                        ForEach(MusicSmartPlaylistLimit.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 18)

            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                Button {
                    var playlist = request.playlist
                    playlist.name = trimmedName
                    playlist.filter = filter
                    playlist.recency = recency
                    playlist.sort = sort
                    playlist.limit = limit
                    onSave(playlist)
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(trimmedName.isEmpty)
            }
        }
        .appSheetChrome(width: 580)
    }

    private func picker<SelectionValue: Hashable, Content: View>(
        selection: Binding<SelectionValue>,
        selectedTitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker("", selection: selection, content: content)
            .labelsHidden()
            .pickerStyle(.menu)
            // 固定统一宽度：各选项框边界一致。
            .adaptiveMenuControl(selectedTitle: selectedTitle, minWidth: Self.optionMenuWidth, maxWidth: Self.optionMenuWidth)
    }

    private static let optionMenuWidth: CGFloat = 150

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func adaptiveFieldWidth(text: String, placeholder: String, minWidth: CGFloat = 120) -> CGFloat {
        let measured = [text, placeholder]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .max { Self.weightedLength($0) < Self.weightedLength($1) } ?? ""
        let contentWidth = max(Self.weightedLength(measured), 4) * 8.4 + 38
        return min(max(contentWidth, minWidth), controlWidth)
    }

    private static func weightedLength(_ text: String) -> CGFloat {
        text.reduce(CGFloat(0)) { partial, character in
            partial + (character.unicodeScalars.contains { $0.value > 0x2E80 } ? 1.55 : 1.0)
        }
    }
}
