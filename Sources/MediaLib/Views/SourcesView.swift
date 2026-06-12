import AppKit
import MediaLibCore
import SwiftUI

private extension RemoteConnectorProvider {
    var sourceDirectoryName: String {
        switch self {
        case .emby:
            return "EMBY"
        case .jellyfin:
            return "Jellyfin"
        case .plex:
            return "Plex"
        default:
            return displayName
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingAddSourceWizard = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "媒体源",
                    subtitle: "管理本地文件夹、移动硬盘、网络挂载、Emby、Jellyfin 和 Plex 媒体库。",
                    systemImage: "externaldrive"
                )

                sourceActionsToolbar

                if let progress = appState.scanProgress, appState.isScanning {
                    ScanProgressView(progress: progress)
                }

                if appState.sources.isEmpty {
                    EmptyStateView(
                        title: "媒体源待添加",
                        systemImage: "externaldrive.badge.plus",
                        message: "接入本地文件夹、移动硬盘、网络挂载、Emby、Jellyfin 或 Plex 媒体库后，MediaLIB 会整理索引。"
                    )
                    .frame(minHeight: 320)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(appState.sources) { source in
                            SourceRowView(source: source)
                        }
                    }
                }
            }
            .pageContainer()
        }
        .suppressHoverEffectsDuringScroll()
        .background(AppPageBackground())
        .navigationTitle("媒体源")
        .onAppear {
            appState.showInterfaceTipOnce(
                key: "sources.health.metadata.toggles",
                message: "每个媒体源都可以单独决定是否参与元数据拉取和健康检查。"
            )
            appState.showInterfaceTipOnce(
                key: "sources.remote.rename.context",
                message: "远程媒体库来源名称不合适时，可以在左侧栏右键它来重命名。"
            )
        }
        .sheet(isPresented: $showingAddSourceWizard) {
            AddMediaSourceWizardSheet(vaultName: appState.settings.privacyVaultName)
                .environmentObject(appState)
        }
    }

    private var sourceActionsToolbar: some View {
        AppSurfaceToolbar {
            Button {
                showingAddSourceWizard = true
            } label: {
                Label("添加媒体源…", systemImage: "plus")
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32, prominent: true))

            Button {
                appState.scanAllSources()
            } label: {
                Label("扫描全部", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))
            .disabled(appState.sources.isEmpty || appState.isScanning)
        }
    }
}

private struct AddMediaSourceWizardSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let vaultName: String
    @State private var step: AddMediaSourceWizardStep = .source
    @State private var selectedKind: AddMediaSourceKind = .local
    @State private var selectedURLs: [URL] = []
    @State private var mediaType: MediaType = .auto
    @State private var networkURL = "smb://"
    @State private var networkUsername = ""
    @State private var networkPassword = ""
    @State private var networkAnonymous = true
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var includeInMetadataFetch = true
    @State private var includeInHealthCheck = true
    @State private var preferMetadataWriteToSource = false
    @State private var remoteTraceSyncMode: RemoteTraceSyncMode = .bidirectional

    private let columns = [GridItem(.adaptive(minimum: 188), spacing: 10)]
    private let mediaTypes: [MediaType] = [
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection
    ]
    private let contentInset: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                AppSheetHeader(
                    title: "添加媒体源",
                    subtitle: stepSubtitle,
                    systemImage: selectedKind.systemImage
                )

                stepIndicator

                detailsArea

                AppSheetActionFooter {
                    Button("取消", role: .cancel) {
                        dismiss()
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))

                    if step != .source {
                        Button("上一步") {
                            withAnimation(AppMotion.standard) {
                                step = previousStep
                            }
                        }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                    }

                    Button {
                        performPrimaryAction()
                    } label: {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                    .disabled(submitDisabled)
                }
            }
            .padding(.horizontal, contentInset)
        }
        .appSheetChrome(width: AppSheetMetrics.wideWidth, maxHeight: 680)
    }

    private var stepSubtitle: String {
        switch step {
        case .source:
            return "选择要接入 MediaLIB 的来源类型。"
        case .configure:
            return selectedKind.configureSubtitle
        case .settings:
            return "确认扫描、健康检查和同步策略。"
        }
    }

    private var stepIndicator: some View {
        // 三步对称排布：来源贴左、设置贴右（左右留白相等）、连接居中；
        // 两段连接线等宽伸缩，保证中间步骤恰好在水平中点。
        HStack(spacing: 8) {
            wizardStepPill(title: "来源", index: 1, active: step == .source, completed: step.order > AddMediaSourceWizardStep.source.order, alignment: .leading)
            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 2)
            wizardStepPill(title: "连接", index: 2, active: step == .configure, completed: step.order > AddMediaSourceWizardStep.configure.order, alignment: .center)
            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 2)
            wizardStepPill(title: "设置", index: 3, active: step == .settings, completed: false, alignment: .trailing)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 0.9)
    }

    private func wizardStepPill(title: String, index: Int, active: Bool, completed: Bool, alignment: Alignment) -> some View {
        HStack(spacing: 7) {
            Image(systemName: completed ? "checkmark.circle.fill" : "\(index).circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(active || completed ? AppColors.selectedGlassTint : .secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(width: 92, alignment: alignment)
    }

    @ViewBuilder
    private var detailsArea: some View {
        switch step {
        case .source:
            sourceSelection
        case .configure:
            switch selectedKind {
            case .local:
                localConfiguration
            case .network:
                networkConfiguration
            case .emby, .jellyfin, .plex:
                remoteConfiguration
            }
        case .settings:
            wizardSettings
        }
    }

    private var sourceSelection: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(AddMediaSourceKind.allCases) { kind in
                sourceKindCard(kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceKindCard(_ kind: AddMediaSourceKind) -> some View {
        Button {
            withAnimation(AppMotion.fast) {
                selectedKind = kind
            }
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: kind.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selectedKind == kind ? AppColors.selectedGlassTint : .secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(kind.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .staticSurfaceBackground(selected: selectedKind == kind, cornerRadius: 14, thickness: 0.94)
            .pointerLiquidEdge(cornerRadius: 14, intensity: 0.82)
        }
        .buttonStyle(.plain)
    }

    private var localConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    chooseLocalDirectories()
                } label: {
                    Label(selectedURLs.isEmpty ? "选择文件夹" : "重新选择文件夹", systemImage: "folder.badge.plus")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32, prominent: selectedURLs.isEmpty))

                Text(localSelectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if !selectedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(selectedURLs.prefix(4), id: \.path) { url in
                        Label(folderTitle(url), systemImage: "folder")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if selectedURLs.count > 4 {
                        Text("另有 \(selectedURLs.count - 4) 个文件夹")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .staticSurfaceBackground(cornerRadius: 14)
            }

            sectionTitle("分类")
            MediaTypeGridPicker(selection: $mediaType, mediaTypes: mediaTypes, vaultName: vaultName)

            AppInfoNote(text: "添加后会立即进入扫描队列；更多参与策略会在下一步确认。", systemImage: "arrow.clockwise")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var networkConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("网络地址")
            TextField("smb://nas.local/Media 或 ftp://192.168.1.10/Movies", text: $networkURL)
                .glassFormField()

            Toggle("匿名登录", isOn: $networkAnonymous)

            if !networkAnonymous {
                TextField("用户名", text: $networkUsername)
                    .glassFormField()
                SecureField("密码", text: $networkPassword)
                    .glassFormField()
            }

            sectionTitle("分类")
            MediaTypeGridPicker(selection: $mediaType, mediaTypes: mediaTypes, vaultName: vaultName)

            AppInfoNote(text: "MediaLIB 会先让 macOS 打开网络位置，再从已挂载目录中选择真实扫描路径。参与策略会在下一步确认。", systemImage: "externaldrive.connected.to.line.below")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remoteConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("服务器")
            TextField(serverPlaceholder, text: $server)
                .glassFormField()

            if selectedKind == .plex {
                SecureField("Plex Token", text: $token)
                    .glassFormField()
            } else {
                TextField("用户名", text: $username)
                    .glassFormField()
                SecureField("密码", text: $password)
                    .glassFormField()
            }

            AppInfoNote(text: credentialNote, systemImage: "lock")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wizardSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SourceBehaviorSettingsPanel(
                isRemoteMediaServer: selectedKind.isRemoteMediaServer,
                includeInMetadataFetch: $includeInMetadataFetch,
                includeInHealthCheck: $includeInHealthCheck,
                preferMetadataWriteToSource: $preferMetadataWriteToSource,
                remoteTraceSyncMode: $remoteTraceSyncMode
            )

            AppInfoNote(text: selectedKind.isRemoteMediaServer ? "这些设置会随远程媒体源一起保存，后续可在媒体源行的设置按钮中修改。" : "这些设置会随目录媒体源一起保存，后续可在媒体源行的设置按钮中修改。", systemImage: "slider.horizontal.3")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
    }

    private var localSelectionSummary: String {
        if selectedURLs.isEmpty {
            return "尚未选择目录"
        }
        if selectedURLs.count == 1 {
            return folderTitle(selectedURLs[0])
        }
        return "已选择 \(selectedURLs.count) 个文件夹"
    }

    private func folderTitle(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private func chooseLocalDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "选择"
        if panel.runModal() == .OK {
            withAnimation(AppMotion.fast) {
                selectedURLs = panel.urls
            }
        }
    }

    private var serverPlaceholder: String {
        selectedKind == .plex ? "服务器地址，例如 http://192.168.1.20:32400" : "服务器地址，例如 http://192.168.1.20:8096"
    }

    private var credentialNote: String {
        if selectedKind == .plex {
            return "Plex Token 只保存在本机，用于后续自动同步。MediaLIB 不会使用系统钥匙串。"
        }
        return "登录信息只保存在本机，用于后续自动同步。MediaLIB 不会使用系统钥匙串。"
    }

    private var primaryActionTitle: String {
        switch step {
        case .source:
            return "下一步"
        case .configure:
            return "下一步"
        case .settings:
            switch selectedKind {
            case .local:
                return "添加并扫描"
            case .network:
                return "连接并选择目录"
            case .plex:
                return appState.isConnectingPlex ? "Plex 连接中" : "连接并同步"
            case .emby:
                return appState.isConnectingEmby ? "Emby 连接中" : "登录并同步"
            case .jellyfin:
                return appState.isConnectingJellyfin ? "Jellyfin 连接中" : "登录并同步"
            }
        }
    }

    private var primaryActionIcon: String {
        switch step {
        case .source:
            return "chevron.right"
        case .configure:
            return "chevron.right"
        case .settings:
            switch selectedKind {
            case .local:
                return "folder.badge.plus"
            case .network:
                return "network"
            case .emby, .jellyfin, .plex:
                return "arrow.triangle.2.circlepath"
            }
        }
    }

    private var submitDisabled: Bool {
        switch step {
        case .source:
            return false
        case .configure:
            switch selectedKind {
            case .local:
                return selectedURLs.isEmpty
            case .network:
                return networkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .plex:
                return appState.isConnectingPlex
                    || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .emby:
                return appState.isConnectingEmby
                    || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .jellyfin:
                return appState.isConnectingJellyfin
                    || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .settings:
            switch selectedKind {
            case .local:
                return selectedURLs.isEmpty
            case .network:
                return networkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .plex:
                return appState.isConnectingPlex
            case .emby:
                return appState.isConnectingEmby
            case .jellyfin:
                return appState.isConnectingJellyfin
            }
        }
    }

    private var previousStep: AddMediaSourceWizardStep {
        switch step {
        case .source:
            return .source
        case .configure:
            return .source
        case .settings:
            return .configure
        }
    }

    private func performPrimaryAction() {
        switch step {
        case .source:
            withAnimation(AppMotion.standard) {
                step = .configure
            }
        case .configure:
            withAnimation(AppMotion.standard) {
                step = .settings
            }
        case .settings:
            submitConfiguredSource()
        }
    }

    private func submitConfiguredSource() {
        switch selectedKind {
        case .local:
            let urls = selectedURLs
            let type = mediaType
            let includeMetadata = includeInMetadataFetch
            let includeHealth = includeInHealthCheck
            let preferWrite = preferMetadataWriteToSource
            dismiss()
            appState.addSources(
                urls: urls,
                mediaType: type,
                includeInMetadataFetch: includeMetadata,
                includeInHealthCheck: includeHealth,
                preferMetadataWriteToSource: preferWrite
            )
        case .network:
            connectAndPickDirectory()
        case .emby:
            connectRemoteMediaServer(provider: .emby)
        case .jellyfin:
            connectRemoteMediaServer(provider: .jellyfin)
        case .plex:
            connectRemoteMediaServer(provider: .plex)
        }
    }

    private func connectRemoteMediaServer(provider: RemoteConnectorProvider) {
        let request = (
            server: server,
            username: username,
            password: password,
            token: token,
            includeMetadata: includeInMetadataFetch,
            includeHealth: includeInHealthCheck,
            traceMode: remoteTraceSyncMode
        )
        dismiss()
        Task {
            await Task.yield()
            switch provider {
            case .plex:
                await appState.connectPlexServer(
                    server: request.server,
                    token: request.token,
                    includeInMetadataFetch: request.includeMetadata,
                    includeInHealthCheck: request.includeHealth,
                    remoteTraceSyncMode: request.traceMode
                )
            case .jellyfin:
                await appState.connectJellyfinServer(
                    server: request.server,
                    username: request.username,
                    password: request.password,
                    includeInMetadataFetch: request.includeMetadata,
                    includeInHealthCheck: request.includeHealth,
                    remoteTraceSyncMode: request.traceMode
                )
            default:
                await appState.connectEmbyServer(
                    server: request.server,
                    username: request.username,
                    password: request.password,
                    includeInMetadataFetch: request.includeMetadata,
                    includeInHealthCheck: request.includeHealth,
                    remoteTraceSyncMode: request.traceMode
                )
            }
        }
    }

    private func connectAndPickDirectory() {
        guard let url = credentialURL else {
            appState.alert = AppAlert(title: "网络地址无效", message: "地址需以 smb://、ftp:// 或 ftps:// 开头。")
            return
        }
        let request = (
            networkURL: networkURL,
            username: networkAnonymous ? nil : networkUsername,
            password: networkAnonymous ? nil : networkPassword,
            mediaType: mediaType,
            includeMetadata: includeInMetadataFetch,
            includeHealth: includeInHealthCheck,
            preferWrite: preferMetadataWriteToSource
        )
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "选择目录"
            panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            if panel.runModal() == .OK, let mountedURL = panel.url {
                appState.addNetworkMountedSource(
                    networkURL: request.networkURL,
                    mountedDirectory: mountedURL,
                    username: request.username,
                    password: request.password,
                    mediaType: request.mediaType,
                    includeInMetadataFetch: request.includeMetadata,
                    includeInHealthCheck: request.includeHealth,
                    preferMetadataWriteToSource: request.preferWrite
                )
                dismiss()
            }
        }
    }

    private var credentialURL: URL? {
        guard var components = URLComponents(string: networkURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["smb", "ftp", "ftps"].contains(scheme) else {
            return nil
        }
        if !networkAnonymous {
            components.user = networkUsername.isEmpty ? nil : networkUsername
            components.password = networkPassword.isEmpty ? nil : networkPassword
        }
        return components.url
    }
}

private enum AddMediaSourceWizardStep {
    case source
    case configure
    case settings

    var order: Int {
        switch self {
        case .source: return 0
        case .configure: return 1
        case .settings: return 2
        }
    }
}

private enum AddMediaSourceKind: String, CaseIterable, Identifiable {
    case local
    case network
    case emby
    case jellyfin
    case plex

    var id: String { rawValue }

    var isRemoteMediaServer: Bool {
        switch self {
        case .emby, .jellyfin, .plex:
            return true
        case .local, .network:
            return false
        }
    }

    var title: String {
        switch self {
        case .local:
            return "本地目录"
        case .network:
            return "网络设备"
        case .emby:
            return "Emby"
        case .jellyfin:
            return "Jellyfin"
        case .plex:
            return "Plex"
        }
    }

    var detail: String {
        switch self {
        case .local:
            return "本机硬盘、移动硬盘或已挂载目录"
        case .network:
            return "SMB、FTP 或 FTPS 挂载后扫描"
        case .emby:
            return "登录服务器并同步媒体库"
        case .jellyfin:
            return "登录服务器并同步媒体库"
        case .plex:
            return "服务器地址与 Token 直连"
        }
    }

    var configureSubtitle: String {
        switch self {
        case .local:
            return "选择文件夹并指定分类。"
        case .network:
            return "填写网络地址，挂载后选择实际目录。"
        case .emby:
            return "登录后同步到独立的 EMBY 目录。"
        case .jellyfin:
            return "登录后同步到独立的 Jellyfin 目录。"
        case .plex:
            return "连接后同步到独立的 Plex 目录。"
        }
    }

    var systemImage: String {
        switch self {
        case .local:
            return "externaldrive.badge.plus"
        case .network:
            return "network"
        case .emby:
            return "server.rack"
        case .jellyfin:
            return "externaldrive.connected.to.line.below"
        case .plex:
            return "play.rectangle.on.rectangle"
        }
    }
}

private struct SourceSettingsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let source: MediaSource
    @State private var draft: MediaSource
    @State private var libraries: [EmbyLibrarySummary] = []
    @State private var selectedLibraryIDs: Set<String>
    @State private var syncAll: Bool
    @State private var isLoadingLibraries = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let mediaTypes: [MediaType] = [
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection
    ]

    init(source: MediaSource) {
        self.source = source
        _draft = State(initialValue: source)
        let selected = Set(source.selectedEmbyLibraryIDs)
        _selectedLibraryIDs = State(initialValue: selected)
        _syncAll = State(initialValue: selected.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSheetHeader(
                title: "媒体源设置",
                subtitle: source.sourceKind.isRemoteMediaServer ? "\(source.sourceKind.displayName) · \(remoteLibrarySummary)" : title(for: draft.mediaType),
                systemImage: source.sourceKind.isRemoteMediaServer ? "server.rack" : "slider.horizontal.3"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if source.sourceKind.isRemoteMediaServer {
                        remoteLibrarySection
                    } else {
                        sectionTitle("分类")
                        MediaTypeGridPicker(selection: mediaTypeBinding, mediaTypes: mediaTypes, vaultName: appState.settings.privacyVaultName)
                    }

                    sectionTitle("参与策略")
                    SourceBehaviorSettingsPanel(
                        isRemoteMediaServer: source.sourceKind.isRemoteMediaServer,
                        includeInMetadataFetch: includeInMetadataFetchBinding,
                        includeInHealthCheck: includeInHealthCheckBinding,
                        preferMetadataWriteToSource: preferMetadataWriteToSourceBinding,
                        remoteTraceSyncMode: remoteTraceSyncModeBinding
                    )

                    AppInfoNote(text: "保存只更新 MediaLIB 内部媒体源设置；不会移动、删除或重命名媒体文件。", systemImage: "checkmark.shield")
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 520)
            .scrollContentBackground(.hidden)

            AppSheetActionFooter {
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))

                Button {
                    save()
                } label: {
                    Label(isSaving ? "保存中" : saveTitle, systemImage: "checkmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(saveDisabled)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.wideWidth, maxHeight: 700)
        .task(id: source.id) {
            guard source.sourceKind.isRemoteMediaServer else { return }
            await loadLibraries()
        }
    }

    private var remoteLibrarySummary: String {
        let count = selectedLibraryIDs.count
        return syncAll || count == 0 ? "全部媒体库" : "已选 \(count) 个库"
    }

    private var saveTitle: String {
        source.sourceKind.isRemoteMediaServer && librarySelectionChanged ? "保存并同步" : "保存设置"
    }

    private var saveDisabled: Bool {
        isSaving || (source.sourceKind.isRemoteMediaServer && !syncAll && selectedLibraryIDs.isEmpty)
    }

    private var librarySelectionChanged: Bool {
        let selected = syncAll ? Set<String>() : selectedLibraryIDs
        return selected != Set(source.selectedEmbyLibraryIDs)
    }

    private var mediaTypeBinding: Binding<MediaType> {
        Binding(
            get: { draft.mediaType },
            set: { draft.mediaType = $0 }
        )
    }

    private var includeInMetadataFetchBinding: Binding<Bool> {
        Binding(
            get: { draft.includeInMetadataFetch },
            set: { draft.includeInMetadataFetch = $0 }
        )
    }

    private var includeInHealthCheckBinding: Binding<Bool> {
        Binding(
            get: { draft.includeInHealthCheck },
            set: { draft.includeInHealthCheck = $0 }
        )
    }

    private var preferMetadataWriteToSourceBinding: Binding<Bool> {
        Binding(
            get: { draft.preferMetadataWriteToSource },
            set: { draft.preferMetadataWriteToSource = $0 }
        )
    }

    private var remoteTraceSyncModeBinding: Binding<RemoteTraceSyncMode> {
        Binding(
            get: { draft.remoteTraceSyncMode },
            set: { draft.remoteTraceSyncMode = $0 }
        )
    }

    private var remoteLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("同步库")
                Spacer()
                Text(remoteLibrarySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                withAnimation(AppMotion.fast) {
                    syncAll = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: syncAll ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(syncAll ? AppColors.selectedGlassTint : .secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步全部媒体库")
                            .font(.callout.weight(.semibold))
                        Text("服务器新增库也会自动纳入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .staticSurfaceBackground(selected: syncAll, cornerRadius: 14)
                .pointerLiquidEdge(cornerRadius: 14, intensity: 0.82)
            }
            .buttonStyle(.plain)

            remoteLibraryList
        }
        .padding(12)
        .staticSurfaceBackground(cornerRadius: 16)
    }

    @ViewBuilder
    private var remoteLibraryList: some View {
        if isLoadingLibraries {
            ProgressView("正在读取服务器媒体库…")
                .frame(maxWidth: .infinity, minHeight: 130)
                .staticSurfaceBackground(cornerRadius: 14)
        } else if let errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                    Text("媒体库列表读取失败")
                }
                .font(.callout.weight(.semibold))
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await loadLibraries() }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 30))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 14)
        } else if libraries.isEmpty {
            EmptyStateView(
                title: "服务器未返回媒体库",
                systemImage: "rectangle.stack.badge.minus",
                message: "可以保持同步全部，稍后再重新打开设置。"
            )
            .frame(maxWidth: .infinity, minHeight: 150)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(libraries) { library in
                    libraryRow(library)
                }
            }
            .padding(.top, 2)
        }
    }

    private func libraryRow(_ library: EmbyLibrarySummary) -> some View {
        let isSelected = selectedLibraryIDs.contains(library.viewID)
        return Button {
            withAnimation(AppMotion.fast) {
                syncAll = false
                if isSelected {
                    selectedLibraryIDs.remove(library.viewID)
                } else {
                    selectedLibraryIDs.insert(library.viewID)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected && !syncAll ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected && !syncAll ? AppColors.selectedGlassTint : .secondary)
                    .frame(width: 18)
                Image(systemName: library.systemImage)
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(library.collectionTypeDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .staticSurfaceBackground(selected: isSelected && !syncAll, cornerRadius: 12, thickness: 0.94)
            .pointerLiquidEdge(cornerRadius: 12, intensity: 0.78)
        }
        .buttonStyle(.plain)
    }

    private func loadLibraries() async {
        isLoadingLibraries = true
        errorMessage = nil
        do {
            libraries = try await appState.loadEmbyLibraries(for: source)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingLibraries = false
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        var updated = draft
        if !updated.includeInMetadataFetch {
            updated.preferMetadataWriteToSource = false
        }
        let selected = syncAll ? Set<String>() : selectedLibraryIDs
        let shouldRefreshRemoteLibraries = source.sourceKind.isRemoteMediaServer && librarySelectionChanged

        dismiss()
        Task { @MainActor in
            await Task.yield()
            if shouldRefreshRemoteLibraries {
                guard appState.updateSource(updated, notify: false) else { return }
                await appState.updateEmbyLibrarySelection(source: updated, selectedLibraryIDs: selected)
            } else {
                appState.updateSource(updated)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
    }

    private func title(for type: MediaType) -> String {
        type == .privateCollection ? appState.settings.privacyVaultName : type.displayName
    }
}

private extension EmbyLibrarySummary {
    var collectionTypeDisplayName: String {
        switch collectionType?.lowercased() {
        case "movies": return "电影"
        case "tvshows": return "电视剧"
        case "music": return "音乐"
        case "boxsets": return "合集"
        case "playlists": return "播放列表"
        case "homevideos": return "家庭视频"
        case "photos": return "照片"
        case "livetv": return "电视直播"
        case .some(let value) where !value.isEmpty: return value
        default: return "混合媒体库"
        }
    }
}

private struct SourceBehaviorSettingsPanel: View {
    let isRemoteMediaServer: Bool
    @Binding var includeInMetadataFetch: Bool
    @Binding var includeInHealthCheck: Bool
    @Binding var preferMetadataWriteToSource: Bool
    @Binding var remoteTraceSyncMode: RemoteTraceSyncMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("参与元数据拉取", isOn: Binding(
                    get: { includeInMetadataFetch },
                    set: { newValue in
                        includeInMetadataFetch = newValue
                        if !newValue {
                            preferMetadataWriteToSource = false
                        }
                    }
                ))
                Toggle("参与健康检查", isOn: $includeInHealthCheck)
                if !isRemoteMediaServer {
                    Toggle("元数据优先写入源目录", isOn: $preferMetadataWriteToSource)
                        .disabled(!includeInMetadataFetch)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 16)

            if isRemoteMediaServer {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("痕迹数据同步")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: true, vertical: false)

                        Picker("", selection: $remoteTraceSyncMode) {
                            ForEach(RemoteTraceSyncMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .adaptiveMenuControl(selectedTitle: remoteTraceSyncMode.title, minWidth: 150, maxWidth: 240)

                        Spacer(minLength: 0)
                    }
                    Text(remoteTraceSyncMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .staticSurfaceBackground(cornerRadius: 16)
            }
        }
    }
}

private struct MediaTypeGridPicker: View {
    @Binding var selection: MediaType
    let mediaTypes: [MediaType]
    let vaultName: String

    private let columns = Array(repeating: GridItem(.flexible(minimum: 118), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(mediaTypes, id: \.self) { type in
                Button {
                    withAnimation(AppMotion.fast) {
                        selection = type
                    }
                } label: {
                    GlassCapsuleControl(isSelected: selection == type, height: 30, horizontalPadding: 10, enablePointerEdge: false) {
                        Label(title(for: type), systemImage: icon(for: type))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .buttonStyle(.plain)
                .help(title(for: type))
            }
        }
        .padding(10)
        .staticSurfaceBackground(cornerRadius: 16)
    }

    private func title(for type: MediaType) -> String {
        type == .privateCollection ? vaultName : type.displayName
    }

    private func icon(for type: MediaType) -> String {
        switch type {
        case .auto: return "wand.and.stars"
        case .movie: return "film"
        case .tvShow: return "tv"
        case .anime: return "sparkles.tv"
        case .documentary: return "books.vertical"
        case .variety: return "theatermasks"
        case .music: return "music.note"
        case .other: return "tray"
        case .privateCollection: return "lock"
        case .episode: return "list.number"
        }
    }
}

struct SourceRowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let source: MediaSource
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var showingSettings = false

    var body: some View {
        let isLockedPrivateSource = source.mediaType == .privateCollection && !appState.privacyUnlocked
        let isReachable = appState.sourceIsReachable(source)

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isReachable ? AppColors.selectedGlassTint.opacity(0.12) : Color.orange.opacity(0.14))
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(isReachable ? AppColors.selectedGlassTint.opacity(0.90) : Color.orange.opacity(0.88))
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(sourceTitle(isLockedPrivateSource: isLockedPrivateSource))
                        .font(.headline)
                }
                if isLockedPrivateSource {
                    Text("路径已隐藏，解锁\(appState.settings.privacyVaultName)后可查看。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    // 路径过长时截断；鼠标悬停在该行时循环滚动完整路径。
                    MarqueeText(text: source.displayPath, font: .caption)
                        .frame(height: 15)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                if !isReachable {
                    Text("不可访问")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.orange)
                        .frame(width: 58, alignment: .trailing)
                }

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 32, thickness: 0.96))
                .help("设置")

                if !isReachable, appState.canRemountNetworkSource(source) {
                    Button {
                        appState.remountNetworkSource(source)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 32, thickness: 0.96))
                    .help("重新挂载")
                }

                Button {
                    appState.scan(source)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 32, thickness: 0.96))
                .disabled(appState.isScanning || !isReachable)
                .help("扫描")

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.red)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 32, thickness: 0.96))
                .help("删除")
                .confirmationDialog(
                    "删除媒体源「\(sourceTitle(isLockedPrivateSource: isLockedPrivateSource))」？",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        appState.deleteSource(source)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将从媒体库移除该来源已索引的条目；你磁盘上的原始文件不会被删除。")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .staticSurfaceBackground(selected: isHovering && !suppressHoverDuringScroll, cornerRadius: 18)
        .scaleEffect(!reduceMotion && isHovering && !suppressHoverDuringScroll ? 1.002 : 1)
        .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering && !suppressHoverDuringScroll)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .sheet(isPresented: $showingSettings) {
            SourceSettingsSheet(source: source)
                .environmentObject(appState)
        }
    }

    private var iconName: String {
        if !appState.sourceIsReachable(source) {
            return "externaldrive.badge.exclamationmark"
        }
        switch source.sourceKind {
        case .emby, .jellyfin, .plex:
            return "server.rack"
        case .smb, .ftp:
            return "network"
        case .local:
            return "externaldrive.fill"
        }
    }

    private func sourceTitle(isLockedPrivateSource: Bool) -> String {
        if isLockedPrivateSource {
            return "\(appState.settings.privacyVaultName)媒体源"
        }
        if source.sourceKind.isRemoteMediaServer {
            return source.sourceKind.displayName
        }
        return source.name
    }

}
