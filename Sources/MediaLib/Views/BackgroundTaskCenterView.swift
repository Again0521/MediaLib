import SwiftUI

struct BackgroundTaskCenterView: View {
    @EnvironmentObject private var appState: AppState

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
                            Label("取消扫描", systemImage: "stop.circle")
                        }
                    }
                    if appState.backgroundTasks.contains(where: { !$0.state.isActive }) {
                        Button(role: .destructive) {
                            appState.clearCompletedBackgroundTasks()
                        } label: {
                            Label("清除记录", systemImage: "trash")
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
        HStack(spacing: 12) {
            PlayfulSymbolIcon(systemImage: task.kind.systemImage, size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                    Text(task.state.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(task.state == .failed ? .red : .secondary)
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
        .staticSurfaceBackground(cornerRadius: 15, thickness: 0.94)
    }

    @ViewBuilder
    private func taskActions(_ task: BackgroundTaskSnapshot) -> some View {
        if task.state == .failed, appState.canRetryBackgroundTask(task) {
            Button {
                appState.retryBackgroundTask(task)
            } label: {
                Image(systemName: "arrow.clockwise.circle")
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
                            Image(systemName: "play.circle")
                        }
                        .help("继续缓存")
                    } else if task.state == .pausing {
                        Image(systemName: "pause.circle")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .help("正在暂停缓存")
                    } else {
                        Button {
                            appState.pauseBackgroundTask(id: task.id)
                        } label: {
                            Image(systemName: "pause.circle")
                        }
                        .help("暂停缓存")
                    }

                    Button(role: .destructive) {
                        appState.cancelBackgroundTask(id: task.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("取消缓存")
                }
            } else if task.kind == .fullScan || task.kind == .incrementalScan {
                Button(role: .destructive) {
                    appState.cancelBackgroundTask(id: task.id)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .help("取消扫描")
            }
        }
    }
}
