import MediaLibCore
import SwiftUI

struct LibraryHealthCenterView: View {
    @EnvironmentObject private var appState: AppState
    @State private var removalRequest: MissingIndexRemovalRequest?
    @State private var duplicateMergeRequest: DuplicateMergeRequest?
    // 健康中心的“补充”复用详情页/音乐库的 MetadataSearchView，保持匹配和写入策略一致。
    @State private var metadataItem: MediaItem?
    @State private var restoredReturnAnchorID: String?

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    summary

                    if hasIssues {
                        offlineSourcesSection
                        missingFilesSection
                        duplicateGroupsSection
                        missingMetadataSection
                    } else {
                        EmptyStateView(
                            title: "片库状态良好",
                            systemImage: "checkmark.seal",
                            message: "未发现离线来源、失效路径、疑似重复项或关键信息缺失。"
                        )
                        .frame(minHeight: 340)
                    }
                }
                .pageContainer()
            }
            .onAppear {
                restoreReturnAnchorIfNeeded(appState.selectedItemReturnAnchorID, scrollProxy: scrollProxy)
            }
            .onChange(of: appState.selectedItemReturnAnchorID) { anchorID in
                restoreReturnAnchorIfNeeded(anchorID, scrollProxy: scrollProxy)
            }
        }
        .suppressHoverEffectsDuringScroll()
        .background(AppPageBackground())
        .navigationTitle("片库健康")
        .onAppear {
            appState.showInterfaceTipOnce(
                key: "health.supplement.metadata",
                message: "一键补充只填空缺，不会覆盖已有信息。"
            )
        }
        .confirmationDialog(
            removalRequest?.title ?? "确认从索引移除？",
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { if !$0 { removalRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("仅从 MediaLIB 索引移除", role: .destructive) {
                if let request = removalRequest {
                    appState.removeMissingItemsFromIndex(request.items)
                }
                removalRequest = nil
            }
            Button("取消", role: .cancel) {
                removalRequest = nil
            }
        } message: {
            Text("仅移除 MediaLIB 内部索引，不会修改媒体文件；离线来源中的条目会保留。")
        }
        .confirmationDialog(
            duplicateMergeRequest?.title ?? "合并重复项？",
            isPresented: Binding(
                get: { duplicateMergeRequest != nil },
                set: { if !$0 { duplicateMergeRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("保留并移除其余", role: .destructive) {
                if let request = duplicateMergeRequest {
                    appState.resolveDuplicateGroup(keeping: request.kept, in: request.group)
                }
                duplicateMergeRequest = nil
            }
            Button("取消", role: .cancel) {
                duplicateMergeRequest = nil
            }
        } message: {
            Text("仅从 MediaLIB 内部索引移除同组其余条目，不会修改媒体文件。")
        }
        .sheet(item: $metadataItem) { item in
            MetadataSearchView(item: item)
                .environmentObject(appState)
        }
    }

    private var header: some View {
        PageHeader(
            title: "片库健康",
            subtitle: "检查来源、文件/播放路径、重复项和关键信息。",
            systemImage: "stethoscope"
        ) {
            if !safeMissingItems.isEmpty {
                Button(role: .destructive) {
                    removalRequest = MissingIndexRemovalRequest(items: safeMissingItems)
                } label: {
                    Label("清理失效索引", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
            if !appState.missingMetadataItems.isEmpty {
                Button {
                    appState.supplementMissingMetadataFromHealth()
                } label: {
                    Label(appState.isSupplementingMetadata ? "补充中…" : "一键补充", systemImage: "tag.badge.plus")
                }
                .disabled(appState.isSupplementingMetadata)
            }
            Button {
                appState.scanAllSources()
            } label: {
                Label("扫描全部", systemImage: "arrow.clockwise")
            }
            .disabled(appState.sources.isEmpty || appState.isScanning)
            Button {
                appState.refreshLibraryHealth()
            } label: {
                Label("重新检查", systemImage: "stethoscope")
            }
        }
    }

    private var summary: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: 4), spacing: 12) {
            healthMetric(title: "离线媒体源", value: appState.offlineSources.count, systemImage: "externaldrive.badge.exclamationmark")
            healthMetric(title: "失效路径", value: appState.missingFileItems.count, systemImage: "doc.badge.ellipsis")
            healthMetric(title: "疑似重复组", value: appState.duplicateTitleGroups.count, systemImage: "square.on.square")
            healthMetric(title: "元数据缺口", value: appState.missingMetadataItems.count, systemImage: "tag.slash")
        }
    }

    private func healthMetric(title: String, value: Int, systemImage: String) -> some View {
        HStack(spacing: 12) {
            PlayfulSymbolIcon(systemImage: systemImage, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .staticSurfaceBackground(cornerRadius: 16)
    }

    @ViewBuilder
    private var offlineSourcesSection: some View {
        if !appState.offlineSources.isEmpty {
            healthSection(title: "离线媒体源", subtitle: "恢复挂载后即可继续扫描；暂时离线不会清理条目。", systemImage: "externaldrive.badge.exclamationmark") {
                ForEach(appState.offlineSources) { source in
                    HStack(spacing: 12) {
                        PlayfulSymbolIcon(systemImage: source.sourceKind == .local ? "externaldrive" : "network", size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hiddenSourceName(source))
                                .font(.callout.weight(.semibold))
                            Text(hiddenSourcePath(source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if appState.canRemountNetworkSource(source) {
                            Button {
                                appState.remountNetworkSource(source)
                            } label: {
                                Label("重新挂载", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        Button {
                            appState.scan(source)
                        } label: {
                            Label("扫描", systemImage: "arrow.clockwise")
                        }
                        .disabled(!appState.sourceIsReachable(source) || appState.isScanning)
                    }
                    .healthRow()
                }
            }
        }
    }

    @ViewBuilder
    private var missingFilesSection: some View {
        if !appState.missingFileItems.isEmpty {
            healthSection(title: "失效文件/播放路径", subtitle: "本地文件不存在或远程视频没有可播放路径时会出现在这里。确认失效后可仅从内部索引移除，离线来源中的路径会保留。", systemImage: "doc.badge.ellipsis") {
                ForEach(appState.missingFileItems) { item in
                    healthItemRow(item, detail: hiddenMissingFileDetail(item)) {
                        Button {
                            openDetail(item)
                        } label: {
                            Label("查看", systemImage: "info.circle")
                        }
                        if appState.canRemoveMissingItemFromIndex(item) {
                            Button(role: .destructive) {
                                removalRequest = MissingIndexRemovalRequest(items: [item])
                            } label: {
                                Label("移出索引", systemImage: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .id(item.id)
                }
            }
        }
    }

    @ViewBuilder
    private var duplicateGroupsSection: some View {
        if !appState.duplicateTitleGroups.isEmpty {
            healthSection(title: "疑似重复条目", subtitle: "按标题、类型和年份列出候选项，需要手动核对。", systemImage: "square.on.square") {
                ForEach(appState.duplicateTitleGroups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(group.first?.title ?? "重复条目")
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text("\(group.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(group) { item in
                            healthItemRow(item, detail: duplicateDetail(item)) {
                                Button {
                                    openDetail(item)
                                } label: {
                                    Label("核对", systemImage: "arrow.up.forward.square")
                                }
                                if group.count > 1 {
                                    Button {
                                        duplicateMergeRequest = DuplicateMergeRequest(kept: item, group: group)
                                    } label: {
                                        Label("保留此项", systemImage: "checkmark.circle")
                                    }
                                }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(14)
                    .staticSurfaceBackground(cornerRadius: 16, thickness: 0.96)
                }
            }
        }
    }

    @ViewBuilder
    private var missingMetadataSection: some View {
        if !appState.missingMetadataItems.isEmpty {
            healthSection(title: "核心元数据缺口", subtitle: "列出缺少封面、年份、简介或音乐标签的条目。", systemImage: "tag.slash") {
                ForEach(appState.missingMetadataItems) { item in
                    healthItemRow(item, detail: missingMetadataDescription(item)) {
                        Button {
                            metadataItem = item
                        } label: {
                            Label("补充", systemImage: "magnifyingglass")
                        }
                    }
                    .id(item.id)
                }
            }
        }
    }

    private func healthSection<Content: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        CollapsibleHealthSection(title: title, subtitle: subtitle, systemImage: systemImage, content: content)
    }

    private func healthItemRow<Actions: View>(
        _ item: MediaItem,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            PlayfulSymbolIcon(systemImage: item.type == .music ? "music.note" : "play.rectangle", size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.cardTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            actions()
        }
        .healthRow()
    }

    private var hasIssues: Bool {
        !appState.offlineSources.isEmpty ||
            !appState.missingFileItems.isEmpty ||
            !appState.duplicateTitleGroups.isEmpty ||
            !appState.missingMetadataItems.isEmpty
    }

    private var safeMissingItems: [MediaItem] {
        appState.missingFileItems.filter(appState.canRemoveMissingItemFromIndex)
    }

    private func hiddenSourcePath(_ source: MediaSource) -> String {
        if source.mediaType == .privateCollection, !appState.privacyUnlocked {
            return "路径已隐藏"
        }
        return source.displayPath
    }

    private func hiddenSourceName(_ source: MediaSource) -> String {
        if source.mediaType == .privateCollection, !appState.privacyUnlocked {
            return "保险库媒体源"
        }
        return source.name
    }

    private func hiddenMissingFileDetail(_ item: MediaItem) -> String {
        // 健康检查上游已过滤锁定保险库内容；这里再兜底一次，避免未来入口变更时泄露路径。
        if appState.isPrivateItem(item), !appState.privacyUnlocked {
            return "路径已隐藏"
        }
        if appState.source(for: item)?.sourceKind.isRemoteMediaServer == true,
           item.filePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return "远程播放路径未记录"
        }
        return item.filePath ?? "路径未记录"
    }

    private func duplicateDetail(_ item: MediaItem) -> String {
        let path = appState.isPrivateItem(item) && !appState.privacyUnlocked ? "路径已隐藏" : item.filePath
        return [item.type.displayName, item.displayYear, path]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    private func missingMetadataDescription(_ item: MediaItem) -> String {
        var missing: [String] = []
        if item.posterPath == nil { missing.append("封面") }
        if item.type == .music {
            if item.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("艺术家") }
            if item.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("专辑") }
        } else {
            if item.year == nil { missing.append("年份") }
            if item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("简介") }
        }
        return "缺少：\(missing.joined(separator: "、"))"
    }

    private func openDetail(_ item: MediaItem) {
        appState.selectedItemReturnAnchorID = item.id
        appState.selectedItem = item
    }

    private func restoreReturnAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard let anchorID, restoredReturnAnchorID != anchorID else { return }
        restoredReturnAnchorID = anchorID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollProxy.scrollTo(anchorID, anchor: .center)
        }
        Task { @MainActor in
            await Task.yield()
            var retryTransaction = Transaction()
            retryTransaction.disablesAnimations = true
            withTransaction(retryTransaction) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
            }
            appState.selectedItemReturnAnchorID = nil
        }
    }
}

private struct MissingIndexRemovalRequest: Identifiable {
    let id = UUID()
    let items: [MediaItem]

    var title: String {
        items.count == 1 ? "确认从索引移除“\(items[0].title)”？" : "确认从索引移除 \(items.count) 个失效条目？"
    }
}

private struct DuplicateMergeRequest: Identifiable {
    let id = UUID()
    let kept: MediaItem
    let group: [MediaItem]

    var removeCount: Int { max(group.count - 1, 0) }
    var title: String { "保留“\(kept.title)”，从索引移除同组其余 \(removeCount) 项？" }
}

private extension View {
    func healthRow() -> some View {
        HealthRowSurface { self }
    }
}

/// 可折叠的健康度分组：标题栏可点击展开/收起，带 chevron 旋转与内容过渡动画；
/// 标题栏鼠标悬停有高亮反馈（任务 4/6）。
private struct CollapsibleHealthSection<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    @State private var expanded = true
    @State private var headerHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : AppMotion.standard) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    PlayfulSymbolIcon(systemImage: systemImage, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .padding(.top, 4)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(headerHovering ? 0.06 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { headerHovering = $0 }
            .animation(reduceMotion ? nil : AppMotion.fast, value: headerHovering)

            if expanded {
                LazyVStack(spacing: 10) {
                    content()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

/// 健康度条目行容器：鼠标悬停有表面高亮 + 轻微放大，参照媒体源行的悬停反馈（任务 7）。
private struct HealthRowSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll

    var body: some View {
        let active = isHovering && !suppressHoverDuringScroll
        content()
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 9, minHeight: 30, thickness: 0.92))
            .padding(12)
            .staticSurfaceBackground(selected: active, cornerRadius: 14, thickness: 0.92)
            .scaleEffect(!reduceMotion && active ? 1.005 : 1)
            .animation(reduceMotion ? nil : AppMotion.fast, value: active)
            .onHover { hovering in
                isHovering = suppressHoverDuringScroll ? false : hovering
            }
    }
}
