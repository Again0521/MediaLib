import AppKit
import MediaLibCore
import SwiftUI

struct LibraryHealthCenterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @State private var removalRequest: MissingIndexRemovalRequest?
    @State private var duplicateMergeRequest: DuplicateMergeRequest?
    // 健康中心的“补充”复用详情页/音乐库的 MetadataSearchView，保持匹配和写入策略一致。
    @State private var metadataItem: MediaItem?
    @State private var restoredReturnAnchorID: String?
    @State private var returnContentReady: Bool
    @State private var hoveringTaskID: UUID?

    init(initialReturnAnchorID: String? = nil) {
        _returnContentReady = State(initialValue: initialReturnAnchorID == nil)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    dashboardOverview

                    healthDetails
                    backgroundTaskDetails
                }
                .pageContainer()
            }
            .opacity(returnContentReady ? 1 : 0)
            .onAppear {
                restoreReturnAnchorIfNeeded(activeReturnContext?.anchorID, scrollProxy: scrollProxy)
                if activeReturnContext == nil {
                    returnContentReady = true
                }
            }
            .onChange(of: activeReturnContext?.anchorID) { anchorID in
                restoreReturnAnchorIfNeeded(anchorID, scrollProxy: scrollProxy)
            }
        }
        .suppressHoverEffectsDuringScroll()
        .background(AppPageBackground())
        .navigationTitle("仪表盘")
        .onAppear {
            appState.showInterfaceTipOnce(
                key: "dashboard.health.tasks",
                message: "仪表盘集中展示片库健康和后台任务；一键补充只填空缺，不会覆盖已有信息。"
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
            title: "仪表盘",
            subtitle: "汇总片库健康、后台任务和需要处理的维护事项。",
            systemImage: "dashboard"
        ) {
            if appState.backgroundTasks.contains(where: { $0.state.isActive && $0.isCancellable && ($0.kind == .fullScan || $0.kind == .incrementalScan) }) {
                Button(role: .destructive) {
                    appState.cancelScanning()
                } label: {
                    Label { Text("取消扫描") } icon: { AppGlyph(systemImage: "stop.circle", size: 15) }
                }
            }
            if appState.backgroundTasks.contains(where: { !$0.state.isActive }) {
                Button(role: .destructive) {
                    appState.clearCompletedBackgroundTasks()
                } label: {
                    Label { Text("清除记录") } icon: { AppGlyph(systemImage: "trash", size: 15) }
                        .foregroundStyle(.red)
                }
            }
            if !safeMissingItems.isEmpty {
                Button(role: .destructive) {
                    removalRequest = MissingIndexRemovalRequest(items: safeMissingItems)
                } label: {
                    Label { Text("清理失效索引") } icon: { AppGlyph(systemImage: "trash", size: 15) }
                        .foregroundStyle(.red)
                }
            }
            if !appState.missingMetadataItems.isEmpty {
                Button {
                    appState.supplementMissingMetadataFromHealth()
                } label: {
                    Label { Text(appState.isSupplementingMetadata ? "补充中…" : "一键补充") } icon: { AppGlyph(systemImage: "tag.badge.plus", size: 15) }
                }
                .disabled(appState.isSupplementingMetadata)
            }
            Button {
                appState.scanAllSources()
            } label: {
                Label { Text("扫描全部") } icon: { AppGlyph(systemImage: "arrow.clockwise", size: 15) }
            }
            .disabled(appState.sources.isEmpty || appState.isScanning)
            Button {
                appState.refreshLibraryHealth()
            } label: {
                Label { Text("重新检查") } icon: { AppGlyph(systemImage: "stethoscope", size: 15) }
            }
        }
    }

    private var dashboardOverview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 188), spacing: 12), count: 4), spacing: 12) {
            DashboardMetricCard(
                title: "健康评分",
                value: "\(healthScore)%",
                subtitle: healthIssueCount == 0 ? "未发现待处理项" : "\(healthIssueCount) 项需处理",
                systemImage: "checkmark.seal",
                tint: healthIssueCount == 0 ? AppColors.selectedGlassTint : .orange,
                progress: Double(healthScore) / 100
            )
            DashboardMetricCard(
                title: "来源可用",
                value: "\(reachableSourceCount)/\(max(appState.sources.count, 1))",
                subtitle: appState.offlineSources.isEmpty ? "全部在线" : "\(appState.offlineSources.count) 个离线",
                systemImage: "externaldrive.badge.checkmark",
                tint: appState.offlineSources.isEmpty ? AppColors.referenceCyan : .orange,
                progress: sourceAvailabilityProgress
            )
            DashboardMetricCard(
                title: "资料完整",
                value: "\(metadataScore)%",
                subtitle: metadataGapCount == 0 ? "资料完整" : "\(metadataGapCount) 个缺口",
                systemImage: "tag",
                tint: metadataGapCount == 0 ? Color.green : Color.orange,
                progress: Double(metadataScore) / 100
            )
            DashboardMetricCard(
                title: "后台任务",
                value: "\(activeTaskCount)",
                subtitle: failedTaskCount > 0 ? "\(failedTaskCount) 个失败可处理" : "\(appState.backgroundTasks.count) 条记录",
                systemImage: "checklist",
                tint: failedTaskCount > 0 ? .red : AppColors.selectedGlassTint,
                progress: taskActivityProgress
            )
        }
    }

    @ViewBuilder
    private var healthDetails: some View {
        AppSectionHeading(
            title: "健康详情",
            subtitle: "来源、路径、重复项与元数据缺口集中处理。",
            systemImage: "stethoscope",
            badgeText: healthIssueCount == 0 ? "正常" : "\(healthIssueCount) 项"
        )
        if hasIssues {
            offlineSourcesSection
            missingFilesSection
            failedLinksSection
            duplicateGroupsSection
            missingMetadataSection
            missingDetailMetadataSection
        } else {
            EmptyStateView(
                title: "片库状态良好",
                systemImage: "checkmark.seal",
                message: "未发现离线来源、失效路径、疑似重复项或关键信息缺失。"
            )
            .frame(minHeight: 220)
            .staticSurfaceBackground(cornerRadius: 18, thickness: 0.94)
        }
    }

    @ViewBuilder
    private var backgroundTaskDetails: some View {
        AppSectionHeading(
            title: "任务记录",
            subtitle: "扫描、同步、缓存和补充任务集中展示。",
            systemImage: "clock.arrow.circlepath",
            badgeText: "\(appState.backgroundTasks.count) 项"
        )
        if appState.backgroundTasks.isEmpty {
            EmptyStateView(
                title: "暂无后台任务",
                systemImage: "checkmark.circle",
                message: "扫描、同步和缓存任务会在运行时集中展示。"
            )
            .frame(minHeight: 220)
            .staticSurfaceBackground(cornerRadius: 18, thickness: 0.94)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(appState.backgroundTasks) { task in
                    taskRow(task)
                }
            }
        }
    }

    @ViewBuilder
    private var offlineSourcesSection: some View {
        if !appState.offlineSources.isEmpty {
            healthSection(title: "离线媒体源", subtitle: "恢复挂载后即可继续扫描；暂时离线不会清理条目。", systemImage: "externaldrive.badge.exclamationmark") {
                ForEach(appState.offlineSources) { source in
                    HStack(spacing: 12) {
                        AppGlyph(systemImage: source.sourceKind == .local ? "externaldrive" : "network", size: 23)
                            .foregroundStyle(AppColors.selectedGlassTint)
                            .frame(width: 28, height: 28)
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
                                Label { Text("重新挂载") } icon: { AppGlyph(systemImage: "arrow.triangle.2.circlepath", size: 14) }
                            }
                        }
                        Button {
                            appState.scan(source)
                        } label: {
                            Label { Text("扫描") } icon: { AppGlyph(systemImage: "arrow.clockwise", size: 14) }
                        }
                        .disabled(!appState.sourceIsReachable(source) || appState.isScanning)
                        ignoreHealthButton(category: AppState.healthCategoryOfflineSource, id: source.id, title: hiddenSourceName(source))
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
                            Label { Text("查看") } icon: { AppGlyph(systemImage: "info.circle", size: 14) }
                        }
                        ignoreHealthButton(category: AppState.healthCategoryMissingFile, id: item.id, title: item.cardTitle)
                        if appState.canRemoveMissingItemFromIndex(item) {
                            Button(role: .destructive) {
                                removalRequest = MissingIndexRemovalRequest(items: [item])
                            } label: {
                                Label { Text("移出索引") } icon: { AppGlyph(systemImage: "trash", size: 14) }
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
                            ignoreHealthButton(
                                category: AppState.healthCategoryDuplicateGroup,
                                id: appState.duplicateHealthIssueID(for: group),
                                title: group.first?.cardTitle ?? "重复条目"
                            )
                        }
                        ForEach(group) { item in
                            healthItemRow(item, detail: duplicateDetail(item)) {
                                Button {
                                    openDetail(item)
                                } label: {
                                    Label { Text("核对") } icon: { AppGlyph(systemImage: "arrow.up.forward.square", size: 14) }
                                }
                                if group.count > 1 {
                                    Button {
                                        duplicateMergeRequest = DuplicateMergeRequest(kept: item, group: group)
                                    } label: {
                                        Label { Text("保留此项") } icon: { AppGlyph(systemImage: "checkmark.circle", size: 14) }
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
                            Label { Text("补充") } icon: { AppGlyph(systemImage: "magnifyingglass", size: 14) }
                        }
                        ignoreHealthButton(category: AppState.healthCategoryMissingMetadata, id: item.id, title: item.cardTitle)
                    }
                    .id(item.id)
                }
            }
        }
    }

    @ViewBuilder
    private var missingDetailMetadataSection: some View {
        if !appState.detailMetadataGapItems.isEmpty {
            healthSection(
                title: "影视详情资料不完整",
                subtitle: "区分缺少人物、艺术照、外部 ID 或推荐；打开详情或等待后台升级任务即可继续补齐。",
                systemImage: "person.crop.rectangle.stack"
            ) {
                ForEach(appState.detailMetadataGapItems) { item in
                    healthItemRow(
                        item,
                        detail: "缺少\(appState.detailMetadataGapDescription(for: item))"
                    ) {
                        Button {
                            openDetail(item)
                        } label: {
                            Label { Text("查看详情") } icon: { AppGlyph(systemImage: "info.circle", size: 14) }
                        }
                        ignoreHealthButton(category: AppState.healthCategoryDetailMetadata, id: item.id, title: item.cardTitle)
                    }
                    .id("detail-metadata-\(item.id)")
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
            AppGlyph(systemImage: item.type == .music ? "music.note" : "play.rectangle", size: 23)
                .foregroundStyle(AppColors.selectedGlassTint)
                .frame(width: 28, height: 28)
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

    private func ignoreHealthButton(category: String, id: String, title: String) -> some View {
        Button {
            appState.ignoreHealthIssue(category: category, id: id, title: title)
        } label: {
            Label { Text("忽略") } icon: { AppGlyph(systemImage: "eye.slash", size: 14) }
        }
        .help("永久忽略此检查结果，可在设置中恢复")
    }

    @ViewBuilder
    private var failedLinksSection: some View {
        if !appState.unhealthyURLItems.isEmpty {
            healthSection(title: "失效链接", subtitle: "URL 媒体源中无法访问或无法解析为视频的地址。可复制链接排查，或从「其他视频」移除。", systemImage: "link.badge.plus") {
                ForEach(appState.unhealthyURLItems) { item in
                    healthItemRow(item, detail: "\(appState.urlItemHealthState(for: item).displayName) · \(item.filePath ?? "")") {
                        Button {
                            if let link = item.filePath {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                                appState.showFloatingNotice(title: "已复制链接", message: link, kind: .success)
                            }
                        } label: {
                            Label { Text("复制链接") } icon: { AppGlyph(systemImage: "link", size: 14) }
                        }
                        Button(role: .destructive) {
                            appState.removeURLVideos(ids: [item.id])
                        } label: {
                            Label { Text("移除") } icon: { AppGlyph(systemImage: "trash", size: 14) }
                                .foregroundStyle(.red)
                        }
                        ignoreHealthButton(category: AppState.healthCategoryUnhealthyURL, id: item.id, title: item.cardTitle)
                    }
                    .id(item.id)
                }
            }
        }
    }

    private func taskRow(_ task: BackgroundTaskSnapshot) -> some View {
        let active = hoveringTaskID == task.id && !suppressHoverDuringScroll
        return HStack(spacing: 12) {
            AppGlyph(systemImage: task.kind.systemImage, size: 26)
                .foregroundStyle(taskStateTint(task.state))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    AppStatusBadge(
                        title: task.state.title,
                        systemImage: taskStateSystemImage(task.state),
                        tint: taskStateTint(task.state)
                    )
                }
                if task.state.isActive, let progress = task.progress {
                    ProgressView(value: progress)
                        .tint(AppColors.selectedGlassTint)
                } else if task.state.isActive {
                    ProgressView()
                        .controlSize(.small)
                }
                if task.hidesDetail {
                    Text("条目、路径和文件名已隐藏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let detail = task.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            taskActions(task)
        }
        .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 9, minHeight: 30, thickness: 0.92))
        .padding(13)
        .appInteractiveSurface(
            active: active,
            selected: task.state.isActive,
            cornerRadius: 15,
            tint: taskStateTint(task.state),
            intensity: task.state.isActive ? 0.78 : 0.56,
            scale: 1.002,
            lift: 1,
            castsHoverShadow: false
        )
        .onHover { hovering in
            hoveringTaskID = hovering && !suppressHoverDuringScroll ? task.id : nil
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing { hoveringTaskID = nil }
        }
    }

    @ViewBuilder
    private func taskActions(_ task: BackgroundTaskSnapshot) -> some View {
        if task.state == .failed, appState.canRetryBackgroundTask(task) {
            Button {
                appState.retryBackgroundTask(task)
            } label: {
                AppGlyph(systemImage: "arrow.clockwise.circle", size: 18)
            }
            .help("重试任务")
        }

        if task.isCancellable, task.state.isActive {
            if task.kind == .videoCache {
                HStack(spacing: 8) {
                    if task.state == .paused {
                        Button {
                            appState.resumeBackgroundTask(id: task.id)
                        } label: {
                            AppGlyph(systemImage: "play.circle", size: 18)
                        }
                        .help("继续缓存")
                    } else if task.state == .pausing {
                        AppGlyph(systemImage: "pause.circle", size: 18)
                            .foregroundStyle(.secondary)
                            .help("正在暂停缓存")
                    } else {
                        Button {
                            appState.pauseBackgroundTask(id: task.id)
                        } label: {
                            AppGlyph(systemImage: "pause.circle", size: 18)
                        }
                        .help("暂停缓存")
                    }

                    Button(role: .destructive) {
                        appState.cancelBackgroundTask(id: task.id)
                    } label: {
                        AppGlyph(systemImage: "xmark.circle", size: 18)
                    }
                    .help("取消缓存")
                }
            } else if task.kind == .fullScan || task.kind == .incrementalScan {
                Button(role: .destructive) {
                    appState.cancelBackgroundTask(id: task.id)
                } label: {
                    AppGlyph(systemImage: "stop.circle", size: 18)
                }
                .help("取消扫描")
            }
        }
    }

    private func taskStateSystemImage(_ state: BackgroundTaskState) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .pausing: return "pause.circle"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func taskStateTint(_ state: BackgroundTaskState) -> Color {
        switch state {
        case .failed: return .red
        case .cancelled, .paused, .pausing: return .orange
        case .completed, .queued, .running: return AppColors.selectedGlassTint
        }
    }

    private var hasIssues: Bool {
        !appState.offlineSources.isEmpty ||
            !appState.missingFileItems.isEmpty ||
            !appState.duplicateTitleGroups.isEmpty ||
            !appState.missingMetadataItems.isEmpty ||
            !appState.detailMetadataGapItems.isEmpty ||
            !appState.unhealthyURLItems.isEmpty
    }

    private var healthIssueCount: Int {
        appState.offlineSources.count +
            appState.missingFileItems.count +
            appState.unhealthyURLItems.count +
            appState.duplicateTitleGroups.count +
            metadataGapCount
    }

    private var metadataGapCount: Int {
        appState.missingMetadataItems.count + appState.detailMetadataGapItems.count
    }

    private var activeTaskCount: Int {
        appState.backgroundTasks.filter { $0.state.isActive }.count
    }

    private var failedTaskCount: Int {
        appState.backgroundTasks.filter { $0.state == .failed }.count
    }

    private var reachableSourceCount: Int {
        max(appState.sources.count - appState.offlineSources.count, 0)
    }

    private var sourceAvailabilityProgress: Double {
        guard !appState.sources.isEmpty else { return 1 }
        return Double(reachableSourceCount) / Double(appState.sources.count)
    }

    private var taskActivityProgress: Double {
        guard !appState.backgroundTasks.isEmpty else { return 1 }
        return Double(activeTaskCount) / Double(max(appState.backgroundTasks.count, 1))
    }

    private var healthScore: Int {
        max(0, min(100, 100 - min(healthIssueCount * 7, 82)))
    }

    private var metadataScore: Int {
        max(0, min(100, 100 - min(metadataGapCount * 6, 80)))
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
        appState.presentDetail(item, from: SidebarDestination.health.id, anchorID: item.id)
    }

    private var activeReturnContext: DetailReturnContext? {
        guard appState.selectedItem == nil,
              appState.detailReturnContext?.destinationID == SidebarDestination.health.id else { return nil }
        return appState.detailReturnContext
    }

    private func restoreReturnAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard let anchorID, restoredReturnAnchorID != anchorID else { return }
        restoredReturnAnchorID = anchorID
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            transaction.animation = nil
            withTransaction(transaction) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
                returnContentReady = true
            }
            await Task.yield()
            guard appState.selectedItem == nil else { return }
            appState.consumeDetailReturnContext(
                destinationID: SidebarDestination.health.id,
                anchorID: anchorID
            )
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

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let progress: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(colorScheme == .dark ? 0.16 : 0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(
                        LinearGradient(colors: [tint, AppColors.referenceCyan.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                AppGlyph(systemImage: systemImage, size: 20)
                    .foregroundStyle(tint)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .staticSurfaceBackground(cornerRadius: 18, thickness: 0.94)
        .accessibilityElement(children: .combine)
    }
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
                HStack(alignment: .center, spacing: 10) {
                    AppSectionHeading(
                        title: title,
                        subtitle: subtitle,
                        systemImage: systemImage
                    )
                    Spacer(minLength: 8)
                    AppGlyph(systemImage: "chevron.down", size: 15)
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
            .accessibilityLabel("\(title)，\(expanded ? "已展开" : "已折叠")")
            .accessibilityHint("切换此健康检查分组")
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
            .appInteractiveSurface(
                active: active,
                cornerRadius: 14,
                tint: AppColors.pointerLightTint,
                intensity: 0.66,
                scale: 1.003,
                lift: 1,
                castsHoverShadow: false
            )
            .animation(reduceMotion ? nil : AppMotion.fast, value: active)
            .onHover { hovering in
                isHovering = suppressHoverDuringScroll ? false : hovering
            }
    }
}
