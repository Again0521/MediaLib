import AppKit
import MediaLibCore
import SwiftUI

private enum DashboardWidgetMetrics {
    static let gap: CGFloat = AppWidgetGridMetrics.dashboardGap
    static let overviewMinWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.quarter)
    static let pairedMinWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.half)
    static let pairedMaxWidth: CGFloat = AppWidgetGridMetrics.fractionalMinWidth(.full)
    static let summaryHeight: CGFloat = AppWidgetGridMetrics.dashboardHeight(.quarter)
    static let sourceListMaxHeight: CGFloat = AppWidgetGridMetrics.dashboardHeight(.half)
    static let taskListMaxHeight: CGFloat = AppWidgetGridMetrics.dashboardHeight(.half)
    static let metadataListHeight: CGFloat = AppWidgetGridMetrics.dashboardHeight(.half)
    static let maintenanceListMaxHeight: CGFloat = AppWidgetGridMetrics.dashboardHeight(.threeQuarters)
    static let sourceRowsMaxHeight: CGFloat = sourceListMaxHeight - 106
    static let taskRowsMaxHeight: CGFloat = taskListMaxHeight - 70
    static let maintenanceRowsMaxHeight: CGFloat = maintenanceListMaxHeight - 48
}

// MARK: - 仪表盘（彻底重写版）
//
// 结构：页眉 → 概览指标环 → 媒体库构成 / 离线缓存用量 → 监测中心
//      （挂载源在线 → 任务记录 → 影视/音乐元数据 → 健康详情）。
//
// 设计铁律：
// 1. 所有区块使用 `.adaptive` 自适应网格：窗口收窄自动降列，最小窗口（内容宽 1088，扣除侧栏后
//    正文约 740pt）下不破排版，也不会把页面撑宽。
// 2. 渲染路径零重计算：任何 O(条目数) 统计（每源条目数、健康派生数组）只在 `rebuildDashboardSnapshot()`
//    里做并缓存到 @State；来源在线状态直接读 AppState 已缓存的 `offlineSources`，
//    绝不在 body 里调用会 stat 文件系统的 `sourceIsReachable`——窗口拖拽缩放不再逐帧
//    过滤上万条目或探测 NAS 路径，缩放顺滑。
// 3. 只呈现应用真实存在的功能：元数据统一走「一键补充」（补封面/年份/简介/艺术家/专辑，
//    即 supplementMissingMetadataFromHealth），不虚构任何"声轨识别"等不存在的能力。
// 4. 卡片高度从 DashboardWidgetMetrics/AppWidgetGridMetrics 派生；非全宽卡片使用 1/4、1/2 等固定比例，
//    全宽列表只限制最大高度，内容少时自然收缩，内容多时只在卡片内部滚动。
// 5. 离线来源与元数据缺口的管理入口只在监测卡里出现一次（不再与下方分组重复）；
//    原有的每一个动作（重新挂载/扫描/忽略/补充/查看/移出索引/复制链接/移除/核对/保留此项/
//    任务重试/暂停/继续/取消）全部保留。

struct LibraryHealthCenterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll

    @State private var removalRequest: MissingIndexRemovalRequest?
    @State private var duplicateMergeRequest: DuplicateMergeRequest?
    // 「补充」复用详情页/音乐库的 MetadataSearchView，保持匹配和写入策略一致。
    @State private var metadataItem: MediaItem?
    @State private var restoredReturnAnchorID: String?
    @State private var returnContentReady: Bool
    @State private var stats = DashboardStatistics()
    @State private var healthSnapshot = DashboardHealthSnapshot()

    /// 跨侧栏跳转闭包：子视图不能直接改 ContentView 的 selection，由外部注入（仿 HomeView 模式）。
    private let onOpenSources: () -> Void
    private let onOpenSection: (SidebarDestination) -> Void

    init(
        initialReturnAnchorID: String? = nil,
        onOpenSources: @escaping () -> Void = {},
        onOpenSection: @escaping (SidebarDestination) -> Void = { _ in }
    ) {
        _returnContentReady = State(initialValue: initialReturnAnchorID == nil)
        self.onOpenSources = onOpenSources
        self.onOpenSection = onOpenSection
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    overviewGrid
                    insightGrid
                    monitorSection
                    taskSection
                    maintenanceSection
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
            rebuildDashboardSnapshot()
            appState.showInterfaceTipOnce(
                key: "dashboard.health.tasks",
                message: "仪表盘集中展示片库健康和后台任务；一键补充只填空缺，不会覆盖已有信息。"
            )
        }
        .onChange(of: dashboardSnapshotKey) { _ in
            rebuildDashboardSnapshot()
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

    // MARK: - 页眉（原有 6 个按钮全部保留，出现条件不变）

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
            if !healthSnapshot.safeMissingItems.isEmpty {
                Button(role: .destructive) {
                    removalRequest = MissingIndexRemovalRequest(items: healthSnapshot.safeMissingItems)
                } label: {
                    Label { Text("清理失效索引") } icon: { AppGlyph(systemImage: "trash", size: 15) }
                        .foregroundStyle(.red)
                }
            }
            if !healthSnapshot.missingMetadataItems.isEmpty {
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

    // MARK: - 概览指标环（4 张，原有指标与算法不变）

    private var overviewGrid: some View {
        HStack(alignment: .top, spacing: 12) {
            DashboardRingCard(
                title: "健康评分",
                value: "\(healthScore)%",
                subtitle: healthIssueCount == 0 ? "未发现待处理项" : "\(healthIssueCount) 项需处理",
                systemImage: "checkmark.seal",
                tint: healthIssueCount == 0 ? AppColors.selectedGlassTint : AppColors.semanticWarning,
                progress: Double(healthScore) / 100
            )
            .frame(maxWidth: .infinity)
            DashboardRingCard(
                title: "来源可用",
                value: "\(reachableSourceCount)/\(max(appState.sources.count, 1))",
                subtitle: healthSnapshot.offlineSources.isEmpty ? "全部在线" : "\(healthSnapshot.offlineSources.count) 个离线",
                systemImage: "externaldrive.badge.checkmark",
                tint: healthSnapshot.offlineSources.isEmpty ? AppColors.referenceCyan : AppColors.semanticWarning,
                progress: sourceAvailabilityProgress
            )
            .frame(maxWidth: .infinity)
            DashboardRingCard(
                title: "资料完整",
                value: "\(metadataScore)%",
                subtitle: metadataGapCount == 0 ? "资料完整" : "\(metadataGapCount) 个缺口",
                systemImage: "tag",
                tint: metadataGapCount == 0 ? AppColors.semanticGood : AppColors.semanticWarning,
                progress: Double(metadataScore) / 100
            )
            .frame(maxWidth: .infinity)
            DashboardRingCard(
                title: "后台任务",
                value: "\(activeTaskCount)",
                subtitle: failedTaskCount > 0 ? "\(failedTaskCount) 个失败可处理" : "\(appState.backgroundTasks.count) 条记录",
                systemImage: "checklist",
                tint: failedTaskCount > 0 ? .red : AppColors.selectedGlassTint,
                progress: taskActivityProgress
            )
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 媒体库构成 / 离线缓存用量

    private var insightGrid: some View {
        HStack(alignment: .top, spacing: DashboardWidgetMetrics.gap) {
            compositionCard
                .frame(maxWidth: .infinity, alignment: .top)
            storageCard
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var compositionCard: some View {
        let slices = compositionSlices
        let sum = slices.reduce(0) { $0 + $1.count }
        let total = max(sum, 1)
        return dashboardCard(height: DashboardWidgetMetrics.summaryHeight) {
            HStack(spacing: 9) {
                accentTick(AppColors.referenceBlue)
                Text("媒体库构成")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AppColors.refTitleText)
                Spacer(minLength: 8)
                Text("共 \(sum) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if sum == 0 {
                compactNote("媒体库为空；添加媒体源并扫描后这里会显示构成。")
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(slices) { slice in
                            if slice.count > 0 {
                                Rectangle()
                                    .fill(slice.color)
                                    .frame(width: max(geo.size.width * CGFloat(slice.count) / CGFloat(total), 3))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 6) {
                    ForEach(slices) { slice in
                        HStack(spacing: 5) {
                            Circle().fill(slice.color).frame(width: 7, height: 7)
                            Text(slice.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text("\(slice.count)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(AppColors.refTitleText)
                        }
                    }
                }
            }
        }
    }

    private var storageCard: some View {
        let summary = appState.videoCacheStorageSummary
        let over = summary.isOverLimit
        let fraction: Double = {
            guard let limit = summary.byteLimit, limit > 0 else { return summary.totalBytes > 0 ? 0.05 : 0 }
            return min(Double(summary.totalBytes) / Double(limit), 1)
        }()
        return dashboardCard(height: DashboardWidgetMetrics.summaryHeight) {
            HStack(spacing: 9) {
                accentTick(over ? AppColors.semanticWarning : AppColors.referenceCyan)
                Text("离线缓存用量")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AppColors.refTitleText)
                Spacer(minLength: 8)
                statusPill("\(summary.entryCount) 个缓存", tint: over ? AppColors.semanticWarning : AppColors.refSecondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(over ? AppColors.semanticWarning : AppColors.refTitleText)
                if let limit = summary.byteLimit, limit > 0 {
                    Text("/ \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("· 未设容量上限")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColors.refScanFill)
                    if fraction > 0 {
                        Capsule()
                            .fill(over ? AppColors.semanticWarning : AppColors.referenceBlue)
                            .frame(width: max(geo.size.width * CGFloat(fraction), 6))
                    }
                }
            }
            .frame(height: 9)
            Text(over ? "已超出缓存上限，可在设置中清理或调大上限。" : "离线缓存供视频离线播放使用，上限可在设置中调整。")
                .font(.caption)
                .foregroundStyle(over ? AppColors.semanticWarning : Color.secondary)
        }
    }

    // MARK: - 监测中心（挂载源在线 / 影视元数据 / 音乐元数据）

    @ViewBuilder
    private var monitorSection: some View {
        AppSectionHeading(
            title: "监测中心",
            subtitle: "挂载源在线状态与元数据缺口集中管理，不再在下方重复列出。",
            systemImage: "waveform.path.ecg",
            badgeText: monitorIssueCount == 0 ? "正常" : "\(monitorIssueCount) 项"
        )
        sourceMonitorCard
        HStack(alignment: .top, spacing: DashboardWidgetMetrics.gap) {
            metadataMonitorCard(isMusic: false)
                .frame(maxWidth: .infinity, alignment: .top)
            metadataMonitorCard(isMusic: true)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var sourceMonitorCard: some View {
        // 在线状态只读 AppState 已缓存的 offlineSources（健康检查刷新时更新），
        // 不在渲染路径里做文件系统探测。
        let offlineIDs = healthSnapshot.offlineSourceIDs
        let offlineCount = appState.sources.filter { offlineIDs.contains($0.id) }.count
        return dashboardCard {
            HStack(spacing: 9) {
                accentTick(Color(red: 14 / 255, green: 165 / 255, blue: 233 / 255))
                Text("挂载源在线监测")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AppColors.refTitleText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusPill(
                    offlineCount == 0 ? "全部在线" : "\(offlineCount) 个离线",
                    tint: offlineCount == 0 ? AppColors.semanticGood : AppColors.semanticWarning
                )
            }
            if appState.sources.isEmpty {
                compactNote("尚未添加媒体源，先到「媒体源」接入本地或网络媒体库。")
            } else {
                // 源以芯片网格整宽排布（自适应 2~3 列）：所有源一屏可见、收成 2~3 行，
                // 不用内部滚动隐藏来源，卡片也随源数量自然收缩。
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 264), spacing: 10)], spacing: 10) {
                    ForEach(appState.sources) { source in
                        sourceRow(source, online: !offlineIDs.contains(source.id))
                    }
                }
            }
            Divider().overlay(AppColors.refCardBorder)
            HStack {
                Text(offlineCount == 0 ? "全部来源连通正常" : "\(offlineCount) 个来源需要重新挂载或检查")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    onOpenSources()
                } label: {
                    Label { Text("源配置") } icon: { AppGlyph(systemImage: "arrow.right", size: 13) }
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 9, horizontalPadding: 11, minHeight: 27))
            }
        }
    }

    private func sourceRow(_ source: MediaSource, online: Bool) -> some View {
        let tint: Color = online ? AppColors.referenceBlue : AppColors.semanticWarning
        // 单行行高：左信息 + 右状态/图标动作，不再分两行把卡片撑高。
        return HStack(spacing: 9) {
            AppGlyph(systemImage: source.sourceKind == .local ? "externaldrive" : "network", size: 14)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(hiddenSourceName(source))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(stats.perSourceCounts[source.id, default: 0]) 个条目")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            if online {
                HStack(spacing: 4) {
                    Circle().fill(AppColors.semanticGood).frame(width: 6, height: 6)
                    Text("在线").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            } else {
                // 离线：状态 + 图标按钮（重新挂载/扫描/忽略），原「离线媒体源」三动作原样保留。
                HStack(spacing: 4) {
                    Text("离线").font(.caption2.weight(.bold)).foregroundStyle(AppColors.semanticWarning)
                    if appState.canRemountNetworkSource(source) {
                        iconAction("arrow.triangle.2.circlepath", "重新挂载") {
                            appState.remountNetworkSource(source)
                        }
                    }
                    iconAction("arrow.clockwise", "扫描") {
                        appState.scan(source)
                    }
                    .disabled(appState.isScanning)
                    iconAction("eye.slash", "忽略") {
                        appState.ignoreHealthIssue(
                            category: AppState.healthCategoryOfflineSource,
                            id: source.id,
                            title: hiddenSourceName(source)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppColors.refScanFill.opacity(0.72)))
        .help(hiddenSourcePath(source))
    }

    private func iconAction(_ glyph: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppGlyph(systemImage: glyph, size: 13)
                .foregroundStyle(AppColors.refSecondaryText)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AppColors.refCardBg))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func metadataMonitorCard(isMusic: Bool) -> some View {
        let accent = isMusic
            ? Color(red: 236 / 255, green: 72 / 255, blue: 153 / 255)
            : Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255)
        let items = isMusic ? healthSnapshot.musicMetadataGapItems : healthSnapshot.videoMetadataGapItems
        // 用 maxHeight 而非固定 height：元数据「完整」时卡片收缩到内容高度，不再留半屏空白；
        // 有缺口时列表最多占 metadataRowsMaxHeight，超出在卡内滚动。
        return dashboardCard(maxHeight: DashboardWidgetMetrics.metadataListHeight) {
            HStack(spacing: 9) {
                accentTick(accent)
                Text(isMusic ? "音乐元数据监测" : "影视元数据监测")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(AppColors.refTitleText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusPill(
                    items.isEmpty ? "完整" : "\(items.count) 项缺口",
                    tint: items.isEmpty ? AppColors.semanticGood : accent
                )
            }
            Text(isMusic
                 ? "共 \(stats.musicCount) 首歌曲；缺少封面、艺术家或专辑信息的会列在这里。"
                 : "共 \(appState.homeStats.movieCount) 部电影 · \(appState.homeStats.seriesCount) 部剧集；缺少封面、年份或简介的会列在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                compactNote(isMusic ? "歌曲元数据完整，无需补充。" : "影视元数据完整，无需补充。", glyph: "checkmark.circle", tint: AppColors.semanticGood)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(items) { item in
                            metadataGapRow(item)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: DashboardWidgetMetrics.metadataListHeight - 150)
                HStack(spacing: 9) {
                    Button {
                        appState.supplementMissingMetadataFromHealth()
                    } label: {
                        Label { Text(appState.isSupplementingMetadata ? "补充中…" : "一键补充") } icon: { AppGlyph(systemImage: "tag.badge.plus", size: 13) }
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 9, horizontalPadding: 11, minHeight: 27, prominent: true))
                    .disabled(appState.isSupplementingMetadata)
                    if isMusic {
                        Button {
                            onOpenSection(.music(.unmatched))
                        } label: {
                            Text("未匹配歌曲")
                        }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 9, horizontalPadding: 11, minHeight: 27))
                    }
                }
            }
        }
    }

    private func metadataGapRow(_ item: MediaItem) -> some View {
        HStack(spacing: 8) {
            Text(item.cardTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.refTitleText)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(missingMetadataTag(item))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.semanticWarning)
                .lineLimit(1)
            Button {
                metadataItem = item
            } label: {
                AppGlyph(systemImage: "magnifyingglass", size: 13)
                    .foregroundStyle(AppColors.refSecondaryText)
            }
            .buttonStyle(.plain)
            .help("搜索并补充元数据")
            Button {
                appState.ignoreHealthIssue(category: AppState.healthCategoryMissingMetadata, id: item.id, title: item.cardTitle)
            } label: {
                AppGlyph(systemImage: "eye.slash", size: 13)
                    .foregroundStyle(AppColors.refSecondaryText)
            }
            .buttonStyle(.plain)
            .help("永久忽略此检查结果，可在设置中恢复")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppColors.refScanFill.opacity(0.72)))
        .help(missingMetadataDescription(item))
    }

    // MARK: - 健康详情（失效文件 / 失效链接 / 重复条目 / 影视详情资料；离线源与核心元数据已并入监测卡）

    @ViewBuilder
    private var maintenanceSection: some View {
        AppSectionHeading(
            title: "健康详情",
            subtitle: "失效文件、失效链接、重复条目与影视详情资料集中处理。",
            systemImage: "stethoscope",
            badgeText: maintenanceIssueCount == 0 ? "正常" : "\(maintenanceIssueCount) 项"
        )
        if maintenanceIssueCount == 0 {
            compactNote("未发现失效文件、失效链接、重复条目或影视详情资料缺口。", glyph: "checkmark.seal", tint: AppColors.semanticGood)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    missingFilesGroup
                    failedLinksGroup
                    duplicateGroupsGroup
                    detailMetadataGroup
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: DashboardWidgetMetrics.maintenanceListMaxHeight)
        }
    }

    @ViewBuilder
    private var missingFilesGroup: some View {
        if !healthSnapshot.missingFileItems.isEmpty {
            MaintenanceDisclosure(
                title: "失效文件/播放路径",
                subtitle: "本地文件不存在或远程视频没有可播放路径。确认失效后可仅从内部索引移除。",
                systemImage: "doc.badge.ellipsis",
                count: healthSnapshot.missingFileItems.count
            ) {
                ForEach(healthSnapshot.missingFileItems) { item in
                    maintenanceItemRow(item, detail: hiddenMissingFileDetail(item)) {
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
    private var failedLinksGroup: some View {
        if !healthSnapshot.unhealthyURLItems.isEmpty {
            MaintenanceDisclosure(
                title: "失效链接",
                subtitle: "URL 媒体源中无法访问或无法解析为视频的地址。可复制链接排查，或从「其他视频」移除。",
                systemImage: "link.badge.plus",
                count: healthSnapshot.unhealthyURLItems.count
            ) {
                ForEach(healthSnapshot.unhealthyURLItems) { item in
                    maintenanceItemRow(item, detail: "\(appState.urlItemHealthState(for: item).displayName) · \(item.filePath ?? "")") {
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

    @ViewBuilder
    private var duplicateGroupsGroup: some View {
        if !healthSnapshot.duplicateTitleGroups.isEmpty {
            MaintenanceDisclosure(
                title: "疑似重复条目",
                subtitle: "按标题、类型和年份列出候选项，需要手动核对。",
                systemImage: "square.on.square",
                count: healthSnapshot.duplicateTitleGroups.count
            ) {
                ForEach(healthSnapshot.duplicateTitleGroups, id: \.self) { group in
                    DashboardListRow(isFirst: false) {
                        HStack(spacing: 8) {
                            AppGlyph(systemImage: "square.on.square", size: 15)
                                .foregroundStyle(AppColors.refSubtle)
                            Text(group.first?.title ?? "重复条目")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(group.count) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ignoreHealthButton(
                                category: AppState.healthCategoryDuplicateGroup,
                                id: appState.duplicateHealthIssueID(for: group),
                                title: group.first?.cardTitle ?? "重复条目"
                            )
                            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 9, minHeight: 30, thickness: 0.92))
                        }
                    }
                    ForEach(group) { item in
                        maintenanceItemRow(item, detail: duplicateDetail(item)) {
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
            }
        }
    }

    @ViewBuilder
    private var detailMetadataGroup: some View {
        if !healthSnapshot.detailMetadataGapItems.isEmpty {
            MaintenanceDisclosure(
                title: "影视详情资料不完整",
                subtitle: "区分缺少人物、艺术照、外部 ID 或推荐；打开详情或等待后台升级任务即可继续补齐。",
                systemImage: "person.crop.rectangle.stack",
                count: healthSnapshot.detailMetadataGapItems.count
            ) {
                ForEach(healthSnapshot.detailMetadataGapItems) { item in
                    maintenanceItemRow(item, detail: "缺少\(appState.detailMetadataGapDescription(for: item))") {
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

    private func maintenanceItemRow<Actions: View>(
        _ item: MediaItem,
        isFirst: Bool = false,
        detail: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        DashboardListRow(isFirst: isFirst) {
            HStack(spacing: 12) {
                AppGlyph(systemImage: item.type == .music ? "music.note" : "play.rectangle", size: 22)
                    .foregroundStyle(AppColors.selectedGlassTint)
                    .frame(width: 26, height: 26)
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
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 9, minHeight: 30, thickness: 0.92))
        }
    }

    private func ignoreHealthButton(category: String, id: String, title: String) -> some View {
        Button {
            appState.ignoreHealthIssue(category: category, id: id, title: title)
        } label: {
            Label { Text("忽略") } icon: { AppGlyph(systemImage: "eye.slash", size: 14) }
        }
        .help("永久忽略此检查结果，可在设置中恢复")
    }

    // MARK: - 任务记录（原有单任务动作全部保留；无任何应用不存在的批量能力）

    @ViewBuilder
    private var taskSection: some View {
        AppSectionHeading(
            title: "任务记录",
            subtitle: "扫描、同步、缓存和补充任务集中展示。",
            systemImage: "clock.arrow.circlepath",
            badgeText: activeTaskCount > 0 ? "\(activeTaskCount) 进行中" : "\(appState.backgroundTasks.count) 项"
        )
        if appState.backgroundTasks.isEmpty {
            compactNote("暂无后台任务；扫描、同步和缓存任务会在运行时显示。", glyph: "checkmark.circle", tint: AppColors.semanticGood)
        } else {
            DashboardGroupedList(maxHeight: DashboardWidgetMetrics.taskListMaxHeight) {
                ForEach(Array(appState.backgroundTasks.enumerated()), id: \.element.id) { index, task in
                    DashboardListRow(isFirst: index == 0, hoverTint: taskStateTint(task.state)) {
                        taskRowContent(task)
                    }
                }
            }
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

        if !task.state.isActive {
            Button(role: .destructive) {
                appState.clearBackgroundTask(id: task.id)
            } label: {
                AppGlyph(systemImage: "trash", size: 18)
                    .foregroundStyle(.red)
            }
            .help("清除这条任务记录")
        }
    }

    private func taskDetailText(_ task: BackgroundTaskSnapshot) -> String {
        if task.hidesDetail { return "条目、路径和文件名已隐藏" }
        if let detail = task.detail, !detail.isEmpty { return detail }
        return task.state.title
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
        case .cancelled, .paused, .pausing: return AppColors.semanticWarning
        case .completed, .queued, .running: return AppColors.selectedGlassTint
        }
    }

    // MARK: - 共享小部件

    private func dashboardCard<Content: View>(
        height: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height, alignment: .topLeading)
            .frame(maxHeight: maxHeight, alignment: .topLeading)
            .staticSurfaceBackground(cornerRadius: 22, thickness: 0.94)
            .hoverLiftEffect(cornerRadius: 22)
    }

    private func accentTick(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: 5, height: 16)
    }

    /// 任务/健康详情列表统一取色（供分组列表整行悬停底色使用）。
    private func taskRowContent(_ task: BackgroundTaskSnapshot) -> some View {
        let tint = taskStateTint(task.state)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                AppGlyph(systemImage: task.kind.systemImage, size: 20)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(task.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        AppStatusBadge(
                            title: task.state.title,
                            systemImage: taskStateSystemImage(task.state),
                            tint: tint
                        )
                        Spacer(minLength: 0)
                        if task.state.isActive, let progress = task.progress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(tint)
                        }
                    }
                    Text(taskDetailText(task))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                taskActions(task)
            }
            if task.state.isActive {
                if let progress = task.progress {
                    ProgressView(value: progress)
                        .tint(tint)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 9, horizontalPadding: 8, minHeight: 27, thickness: 0.92))
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
            .foregroundStyle(tint)
    }

    private func compactNote(_ text: String, glyph: String = "info.circle", tint: Color = AppColors.refSecondaryText) -> some View {
        HStack(spacing: 8) {
            AppGlyph(systemImage: glyph, size: 14)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppColors.refScanFill.opacity(0.6)))
    }

    // MARK: - 统计缓存（渲染路径零重计算的关键）

    private struct DashboardStatistics {
        var perSourceCounts: [String: Int] = [:]
        var animeCount = 0
        var photoCount = 0
        var musicCount = 0
    }

    private struct DashboardHealthSnapshot {
        var offlineSources: [MediaSource] = []
        var offlineSourceIDs: Set<String> = []
        var missingFileItems: [MediaItem] = []
        var safeMissingItems: [MediaItem] = []
        var missingMetadataItems: [MediaItem] = []
        var videoMetadataGapItems: [MediaItem] = []
        var musicMetadataGapItems: [MediaItem] = []
        var unhealthyURLItems: [MediaItem] = []
        var duplicateTitleGroups: [[MediaItem]] = []
        var detailMetadataGapItems: [MediaItem] = []

        var monitorIssueCount: Int {
            offlineSources.count + missingMetadataItems.count
        }

        var maintenanceIssueCount: Int {
            missingFileItems.count + unhealthyURLItems.count + duplicateTitleGroups.count + detailMetadataGapItems.count
        }

        var metadataGapCount: Int {
            missingMetadataItems.count + detailMetadataGapItems.count
        }

        var healthIssueCount: Int {
            offlineSources.count + missingFileItems.count + unhealthyURLItems.count + duplicateTitleGroups.count + metadataGapCount
        }
    }

    private var dashboardSnapshotKey: String {
        [
            appState.libraryRevision,
            appState.sources.count,
            appState.settings.ignoredHealthIssueIDs.count,
            appState.privacyUnlocked ? 1 : 0,
        ]
        .map(String.init)
        .joined(separator: "|")
    }

    private func rebuildDashboardSnapshot() {
        rebuildStatistics()
        rebuildHealthSnapshot()
    }

    /// O(条目数) 的统计只在这里做（数据变化时触发一次），结果缓存进 @State。
    private func rebuildStatistics() {
        var perSource: [String: Int] = [:]
        var anime = 0
        var photo = 0
        var music = 0
        let sources = appState.sources
        for item in appState.items {
            switch item.type {
            case .anime: anime += 1
            case .photo: photo += 1
            case .music: music += 1
            default: break
            }
            for source in sources where AppState.isSourcePath(item.sourcePath, inside: source.path) {
                perSource[source.id, default: 0] += 1
                break
            }
        }
        stats = DashboardStatistics(perSourceCounts: perSource, animeCount: anime, photoCount: photo, musicCount: music)
    }

    /// 健康派生数组集中缓存，避免 body 的多个卡片、标题和列表反复过滤千级条目。
    private func rebuildHealthSnapshot() {
        let offlineSources = appState.offlineSources
        let missingFileItems = appState.missingFileItems
        let missingMetadataItems = appState.missingMetadataItems
        let detailMetadataGapItems = appState.detailMetadataGapItems
        healthSnapshot = DashboardHealthSnapshot(
            offlineSources: offlineSources,
            offlineSourceIDs: Set(offlineSources.map(\.id)),
            missingFileItems: missingFileItems,
            safeMissingItems: missingFileItems.filter(appState.canRemoveMissingItemFromIndex),
            missingMetadataItems: missingMetadataItems,
            videoMetadataGapItems: missingMetadataItems.filter { $0.type != .music },
            musicMetadataGapItems: missingMetadataItems.filter { $0.type == .music },
            unhealthyURLItems: appState.unhealthyURLItems,
            duplicateTitleGroups: appState.duplicateTitleGroups,
            detailMetadataGapItems: detailMetadataGapItems
        )
    }

    private struct CompositionSlice: Identifiable {
        let id: String
        let label: String
        let count: Int
        let color: Color
    }

    private var compositionSlices: [CompositionSlice] {
        [
            CompositionSlice(id: "movie", label: "电影", count: appState.homeStats.movieCount, color: AppColors.referenceBlue),
            CompositionSlice(id: "series", label: "剧集", count: appState.homeStats.seriesCount, color: Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255)),
            CompositionSlice(id: "anime", label: "动漫", count: stats.animeCount, color: Color(red: 236 / 255, green: 72 / 255, blue: 153 / 255)),
            CompositionSlice(id: "music", label: "音乐", count: stats.musicCount, color: Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255)),
            CompositionSlice(id: "photo", label: "照片", count: stats.photoCount, color: Color(red: 14 / 255, green: 165 / 255, blue: 233 / 255)),
        ]
    }

    // MARK: - 计数与评分（口径与原版一致）

    private var monitorIssueCount: Int {
        healthSnapshot.monitorIssueCount
    }

    private var maintenanceIssueCount: Int {
        healthSnapshot.maintenanceIssueCount
    }

    private var healthIssueCount: Int {
        healthSnapshot.healthIssueCount
    }

    private var metadataGapCount: Int {
        healthSnapshot.metadataGapCount
    }

    private var activeTaskCount: Int {
        appState.backgroundTasks.filter { $0.state.isActive }.count
    }

    private var failedTaskCount: Int {
        appState.backgroundTasks.filter { $0.state == .failed }.count
    }

    private var reachableSourceCount: Int {
        max(appState.sources.count - healthSnapshot.offlineSources.count, 0)
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

    // MARK: - 文案助手（隐私遮蔽逻辑与原版一致）

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

    /// 缺口字段完整列表（tooltip 用）。
    private func missingMetadataDescription(_ item: MediaItem) -> String {
        "缺少：\(missingMetadataFields(item).joined(separator: "、"))"
    }

    /// 行内短标签：第一个缺口字段 + 计数。
    private func missingMetadataTag(_ item: MediaItem) -> String {
        let fields = missingMetadataFields(item)
        guard let first = fields.first else { return "待补充" }
        return fields.count > 1 ? "缺\(first)等 \(fields.count) 项" : "缺\(first)"
    }

    private func missingMetadataFields(_ item: MediaItem) -> [String] {
        var missing: [String] = []
        if item.posterPath == nil { missing.append("封面") }
        if item.type == .music {
            if item.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("艺术家") }
            if item.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("专辑") }
        } else {
            if item.year == nil { missing.append("年份") }
            if item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missing.append("简介") }
        }
        return missing
    }

    // MARK: - 详情返回锚点（原版行为不变）

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

// MARK: - 支撑类型

private struct ContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

/// 概览指标环卡：图标 + 环形进度 + 数值/副标题，高度紧凑（约 76pt）。
private struct DashboardRingCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let progress: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(colorScheme == .dark ? 0.16 : 0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(
                        LinearGradient(colors: [tint, AppColors.referenceCyan.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    // 重新检查后圆环推进到新值而不是跳变；Reduce Motion 直接取终值。
                    .animation(reduceMotion ? nil : AppMotion.standard, value: progress)
                AppGlyph(systemImage: systemImage, size: 18)
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    // 数值滚动过渡（monospacedDigit 保证不引起布局位移）。
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : AppMotion.standard, value: value)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 0.94)
        .hoverLiftEffect(cornerRadius: 20)
        .accessibilityElement(children: .combine)
    }
}

/// 系统风格分组列表容器：单层白底圆角面板 + 细边框，内部行扁平、用发丝分隔线区隔
/// （macOS「系统设置」分组列表观感）——彻底消除卡片套卡片与直角底层。
struct DashboardGroupedList<Content: View>: View {
    var maxHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if let maxHeight {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0, content: content)
                }
                .frame(maxHeight: maxHeight)
            } else {
                LazyVStack(spacing: 0, content: content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(AppColors.refCardBg))
        .overlay(shape.strokeBorder(AppColors.refCardBorder, lineWidth: 1))
        .clipShape(shape)
        .shadow(color: AppColors.refCardShadow.opacity(0.05), radius: 14, y: 6)
    }
}

/// 分组列表内的扁平行：无独立卡片；非首行顶部一条内缩发丝分隔线；悬停整行淡色底。
struct DashboardListRow<Content: View>: View {
    var isFirst: Bool = false
    var hoverTint: Color = AppColors.selectedGlassTint
    var verticalPadding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll

    var body: some View {
        let active = hovering && !suppressHoverDuringScroll
        VStack(spacing: 0) {
            if !isFirst {
                Rectangle()
                    .fill(AppColors.refRowDivider)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, verticalPadding)
                .background(active ? hoverTint.opacity(0.09) : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = suppressHoverDuringScroll ? false : $0 }
        .animation(reduceMotion ? nil : AppMotion.fast, value: active)
    }
}

/// 健康详情可折叠分组：整块作为一张系统风格分组卡；卡头点击展开/收起，
/// chevron 旋转；展开后条目为扁平行 + 发丝分隔线（不再卡中卡）。
private struct MaintenanceDisclosure<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let count: Int
    @ViewBuilder var content: () -> Content

    @State private var expanded = true
    @State private var headerHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DashboardGroupedList {
            Button {
                withAnimation(reduceMotion ? nil : AppMotion.standard) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppColors.refIconChipBg)
                        .frame(width: 34, height: 34)
                        .overlay {
                            AppGlyph(systemImage: systemImage, size: 16, lineWidth: 2)
                                .foregroundStyle(AppColors.refIconGlyph)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Text("\(count) 项")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AppColors.selectedGlassTint.opacity(0.13)))
                        .foregroundStyle(AppColors.selectedGlassTint)
                    AppGlyph(systemImage: "chevron.down", size: 13)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(headerHovering ? 0.045 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(expanded ? "已展开" : "已折叠")")
            .accessibilityHint("切换此健康检查分组")
            .onHover { headerHovering = $0 }
            .animation(reduceMotion ? nil : AppMotion.fast, value: headerHovering)

            if expanded {
                LazyVStack(spacing: 0, content: content)
            }
        }
    }
}
