import SwiftUI

struct BackgroundTaskCenterView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @State private var hoveringTaskID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "任务中心",
                    subtitle: "查看扫描、文件更新和服务同步进度。",
                    systemImage: "checklist"
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
                }

                if appState.backgroundTasks.isEmpty {
                    EmptyStateView(
                        title: "暂无后台任务",
                        systemImage: "checkmark.circle",
                        message: "扫描、同步和缓存任务会在运行时集中展示。"
                    )
                    .frame(minHeight: 360)
                } else {
                    AppSectionHeading(
                        title: "任务记录",
                        subtitle: "运行中任务优先显示，完成与失败记录保留在下方。",
                        systemImage: "clock.arrow.circlepath",
                        badgeText: "\(appState.backgroundTasks.count) 项"
                    )

                    LazyVStack(spacing: 10) {
                        ForEach(appState.backgroundTasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
            .pageContainer()
        }
        .suppressHoverEffectsDuringScroll()
        .background(AppPageBackground())
        .navigationTitle("任务中心")
        .onAppear {
            appState.showInterfaceTipOnce(
                key: "tasks.cache.controls",
                message: "缓存视频时，可以在这里暂停、继续或取消任务，进度会一直替你记着。"
            )
        }
    }

    private func taskRow(_ task: BackgroundTaskSnapshot) -> some View {
        let active = hoveringTaskID == task.id && !suppressHoverDuringScroll
        return HStack(spacing: 12) {
            AppGlyph(systemImage: task.kind.systemImage, size: 26)
                .foregroundStyle(AppColors.selectedGlassTint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
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
            intensity: task.state.isActive ? 0.84 : 0.62,
            scale: 1.003,
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
        case .completed: return AppColors.selectedGlassTint
        case .queued, .running: return AppColors.selectedGlassTint
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
}
