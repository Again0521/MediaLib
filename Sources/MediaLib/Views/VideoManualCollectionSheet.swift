import MediaLibCore
import SwiftUI

struct VideoManualCollectionEditorRequest: Identifiable {
    let collection: VideoManualCollection
    let isNew: Bool

    var id: String { collection.id }

    static func create() -> VideoManualCollectionEditorRequest {
        VideoManualCollectionEditorRequest(
            collection: VideoManualCollection(name: "新集合"),
            isNew: true
        )
    }

    static func edit(_ collection: VideoManualCollection) -> VideoManualCollectionEditorRequest {
        VideoManualCollectionEditorRequest(collection: collection, isNew: false)
    }
}

struct VideoManualCollectionSheet: View {
    let request: VideoManualCollectionEditorRequest
    let onSave: (VideoManualCollection) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var showOnHome: Bool

    init(
        request: VideoManualCollectionEditorRequest,
        onSave: @escaping (VideoManualCollection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: request.collection.name)
        _showOnHome = State(initialValue: request.collection.showOnHome)
    }

    private let controlWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: request.isNew ? "新建集合" : "重命名集合",
                subtitle: "手动整理想放在一起看的电影、剧集或单集。",
                systemImage: "rectangle.stack"
            )

            VStack(spacing: 14) {
                SettingsRow(title: "名称", systemImage: "pencil.line") {
                    TextField("集合", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .glassFormField()
                        .frame(width: adaptiveFieldWidth(text: name, placeholder: "集合"), alignment: .trailing)
                }
                SettingsRow(title: "首页展示", systemImage: "house") {
                    Toggle("", isOn: $showOnHome)
                        .labelsHidden()
                        .toggleStyle(.switch)
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
                    collection.showOnHome = showOnHome
                    onSave(collection)
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(trimmedName.isEmpty)
            }
        }
        .appSheetChrome(width: 520)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func adaptiveFieldWidth(text: String, placeholder: String, minWidth: CGFloat = 110) -> CGFloat {
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
