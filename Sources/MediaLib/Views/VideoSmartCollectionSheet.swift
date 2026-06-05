import MediaLibCore
import SwiftUI

struct VideoSmartCollectionEditorRequest: Identifiable {
    let collection: VideoSmartCollection
    let isNew: Bool

    var id: String { collection.id }

    static func create() -> VideoSmartCollectionEditorRequest {
        VideoSmartCollectionEditorRequest(
            collection: VideoSmartCollection(name: "新建智能集合"),
            isNew: true
        )
    }

    static func edit(_ collection: VideoSmartCollection) -> VideoSmartCollectionEditorRequest {
        VideoSmartCollectionEditorRequest(collection: collection, isNew: false)
    }
}

struct VideoSmartCollectionSheet: View {
    let request: VideoSmartCollectionEditorRequest
    let onSave: (VideoSmartCollection) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var mediaScope: VideoSmartCollectionMediaScope
    @State private var stateFilter: VideoSmartCollectionStateFilter
    @State private var recency: VideoSmartCollectionRecency

    init(
        request: VideoSmartCollectionEditorRequest,
        onSave: @escaping (VideoSmartCollection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: request.collection.name)
        _mediaScope = State(initialValue: request.collection.mediaScope)
        _stateFilter = State(initialValue: request.collection.stateFilter)
        _recency = State(initialValue: request.collection.recency)
    }

    // 保持右侧控件边界稳定，同时允许菜单和名称输入在安全范围内随文字伸缩。
    private let controlWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: request.isNew ? "新建智能集合" : "编辑智能集合",
                subtitle: "保存筛选规则，内容随媒体库自动更新。",
                systemImage: "sparkles.rectangle.stack"
            )

            VStack(spacing: 14) {
                SettingsRow(title: "名称", systemImage: "pencil.line") {
                    TextField("智能集合", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .glassFormField()
                        .frame(width: Self.optionMenuWidth, alignment: .trailing)
                }
                SettingsRow(title: "媒体类型", systemImage: "film.stack") {
                    picker(selection: $mediaScope, selectedTitle: mediaScope.displayName) {
                        ForEach(VideoSmartCollectionMediaScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                }
                SettingsRow(title: "状态条件", systemImage: "line.3.horizontal.decrease.circle") {
                    picker(selection: $stateFilter, selectedTitle: stateFilter.displayName) {
                        ForEach(VideoSmartCollectionStateFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                }
                SettingsRow(title: "加入时间", systemImage: "calendar.badge.clock") {
                    picker(selection: $recency, selectedTitle: recency.displayName) {
                        ForEach(VideoSmartCollectionRecency.allCases) { option in
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
                    var collection = request.collection
                    collection.name = trimmedName
                    collection.mediaScope = mediaScope
                    collection.stateFilter = stateFilter
                    collection.recency = recency
                    onSave(collection)
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
            // 固定统一宽度：三个选项框边界一致。
            .adaptiveMenuControl(selectedTitle: selectedTitle, minWidth: Self.optionMenuWidth, maxWidth: Self.optionMenuWidth)
    }

    private static let optionMenuWidth: CGFloat = 150

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 弹性宽度：随输入内容/占位文字长度自适应（CJK 字符按 1.55 计权），夹在 [120, controlWidth]。
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
