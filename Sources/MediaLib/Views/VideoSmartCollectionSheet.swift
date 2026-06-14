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
    @State private var matchMode: VideoSmartCollectionRuleMatchMode
    @State private var yearRule: VideoSmartCollectionYearRule
    @State private var providerRatingRule: VideoSmartCollectionProviderRatingRule
    @State private var userRatingRule: VideoSmartCollectionUserRatingRule
    @State private var genreKeyword: String
    @State private var sourceRule: VideoSmartCollectionSourceRule
    @State private var showOnHome: Bool

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
        _matchMode = State(initialValue: request.collection.rules.matchMode)
        _yearRule = State(initialValue: request.collection.rules.year)
        _providerRatingRule = State(initialValue: request.collection.rules.providerRating)
        _userRatingRule = State(initialValue: request.collection.rules.userRating)
        _genreKeyword = State(initialValue: request.collection.rules.genreKeyword)
        _sourceRule = State(initialValue: request.collection.rules.source)
        _showOnHome = State(initialValue: request.collection.showOnHome)
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
                        .frame(width: adaptiveFieldWidth(text: name, placeholder: "智能集合"), alignment: .trailing)
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

            VStack(spacing: 14) {
                SettingsRow(title: "条件关系", systemImage: "checklist") {
                    picker(selection: $matchMode, selectedTitle: matchMode.displayName) {
                        ForEach(VideoSmartCollectionRuleMatchMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
                SettingsRow(title: "年份", systemImage: "calendar") {
                    picker(selection: $yearRule, selectedTitle: yearRule.displayName) {
                        ForEach(VideoSmartCollectionYearRule.allCases) { rule in
                            Text(rule.displayName).tag(rule)
                        }
                    }
                }
                SettingsRow(title: "资料评分", systemImage: "chart.bar") {
                    picker(selection: $providerRatingRule, selectedTitle: providerRatingRule.displayName) {
                        ForEach(VideoSmartCollectionProviderRatingRule.allCases) { rule in
                            Text(rule.displayName).tag(rule)
                        }
                    }
                }
                SettingsRow(title: "我的评级", systemImage: "star") {
                    picker(selection: $userRatingRule, selectedTitle: userRatingRule.displayName) {
                        ForEach(VideoSmartCollectionUserRatingRule.allCases) { rule in
                            Text(rule.displayName).tag(rule)
                        }
                    }
                }
                SettingsRow(title: "题材", systemImage: "tag") {
                    TextField("动作 / 科幻", text: $genreKeyword)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .glassFormField()
                        .frame(width: adaptiveFieldWidth(text: genreKeyword, placeholder: "动作 / 科幻", minWidth: 132), alignment: .trailing)
                }
                SettingsRow(title: "来源", systemImage: "tray.full") {
                    picker(selection: $sourceRule, selectedTitle: sourceRule.displayName) {
                        ForEach(VideoSmartCollectionSourceRule.allCases) { rule in
                            Text(rule.displayName).tag(rule)
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
                    collection.rules = VideoSmartCollectionRules(
                        matchMode: matchMode,
                        year: yearRule,
                        providerRating: providerRatingRule,
                        userRating: userRatingRule,
                        genreKeyword: genreKeyword,
                        source: sourceRule
                    )
                    collection.showOnHome = showOnHome
                    onSave(collection)
                } label: {
                    Label("保存", systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(trimmedName.isEmpty)
            }
        }
        .appSheetChrome(width: 620)
    }

    private func picker<SelectionValue: Hashable, Content: View>(
        selection: Binding<SelectionValue>,
        selectedTitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker("", selection: selection, content: content)
            .adaptiveMenuControl(selectedTitle: selectedTitle, minWidth: Self.optionMenuMinWidth, maxWidth: Self.optionMenuMaxWidth)
    }

    private static let optionMenuMinWidth: CGFloat = 76
    private static let optionMenuMaxWidth: CGFloat = 176

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
