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
        case .mlink:
            return "MediaLIB Server"
        default:
            return displayName
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingAddSourceWizard = false

    /// 来源布局键：扫描进度卡的出现/消失、来源增删、在“已连接/已断开”分组间迁移时
    /// 驱动柔和过渡；行内状态文字更新不参与。
    private var sourcesLayoutKey: String {
        let connected = connectedSources.map(\.id).joined(separator: ",")
        let disconnected = disconnectedSources.map(\.id).joined(separator: ",")
        return "\(appState.isScanning)|\(connected)|\(disconnected)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "媒体源",
                    subtitle: "管理本地文件夹、移动硬盘、网络挂载、MediaLIB Server、Emby、Jellyfin 和 Plex 媒体库。",
                    systemImage: "externaldrive"
                ) {
                    sourceActionsRow
                }

                if let progress = appState.scanProgress, appState.isScanning {
                    ScanProgressView(progress: progress)
                        .transition(.opacity.combined(with: .offset(y: -8)))
                }

                if appState.sources.isEmpty {
                    EmptyStateView(
                        title: "媒体源待添加",
                        systemImage: "externaldrive.badge.plus",
                        message: "接入本地文件夹、移动硬盘、网络挂载、MediaLIB Server、Emby、Jellyfin 或 Plex 媒体库后，MediaLIB 会整理索引。"
                    )
                    .frame(minHeight: 320)
                } else {
                    if !connectedSources.isEmpty {
                        sourcesSection(
                            title: "已连接媒体源",
                            subtitle: "状态、参与策略和扫描操作集中在每个来源行中。",
                            systemImage: "externaldrive.badge.checkmark",
                            tint: AppColors.referenceBlue,
                            count: connectedSources.count
                        )
                        sourcesList(connectedSources)
                    }

                    if !disconnectedSources.isEmpty {
                        sourcesSection(
                            title: "已断开媒体源",
                            subtitle: "这些来源暂时不可访问，可重新挂载、检查设置或稍后再扫描。",
                            systemImage: "externaldrive.badge.exclamationmark",
                            tint: AppColors.semanticWarning,
                            count: disconnectedSources.count
                        )
                        sourcesList(disconnectedSources)
                    }
                }
            }
            .pageContainer()
            // 扫描进度卡滑入滑出、来源增删与分组迁移的布局变化柔和过渡。
            .animation(reduceMotion ? nil : AppMotion.standard, value: sourcesLayoutKey)
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

    private var connectedSources: [MediaSource] {
        appState.sources.filter { appState.sourceIsReachable($0) }
    }

    private var disconnectedSources: [MediaSource] {
        appState.sources.filter { !appState.sourceIsReachable($0) }
    }

    private var sourceActionsRow: some View {
        HStack(spacing: 12) {
            Button {
                showingAddSourceWizard = true
            } label: {
                Label { Text("添加媒体源…") } icon: { AppGlyph(systemImage: "plus", size: 15, lineWidth: 2.2) }
            }
            .buttonStyle(
                HeaderProminentActionButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 18,
                    minHeight: AppControlMetrics.prominentButtonHeight
                )
            )

            Button {
                appState.scanAllSources()
            } label: {
                Label { Text("扫描全部") } icon: { AppGlyph(systemImage: "arrow.clockwise", size: 15) }
            }
            .buttonStyle(
                HeaderActionGlassButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 18,
                    minHeight: AppControlMetrics.prominentButtonHeight
                )
            )
            .disabled(appState.sources.isEmpty || appState.isScanning)
        }
    }

    private func sourcesSection(title: String, subtitle: String, systemImage: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 14) {
            Capsule()
                .fill(tint)
                .frame(width: 4, height: 46)

            VividPageIcon(systemImage: systemImage, chip: 54, glyph: 26, tint: tint)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AppColors.textPrimary)
                Text(subtitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text("\(count)个")
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(tint.opacity(0.10), in: Capsule())
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourcesList(_ sources: [MediaSource]) -> some View {
        LazyVStack(spacing: 14) {
            ForEach(sources) { source in
                SourceRowView(source: source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var urlInput = ""
    @State private var urlTitleInput = ""

    private let columns = [GridItem(.adaptive(minimum: 188), spacing: 10)]
    private let mediaTypes: [MediaType] = [
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .homeVideo, .music, .photo, .other, .privateCollection
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

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailsArea
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 460)
                .scrollContentBackground(.hidden)

                AppSheetActionFooter {
                    Button("取消", role: .cancel) {
                        dismiss()
                    }
                    .buttonStyle(AppSheetSecondaryButtonStyle())

                    if step != .source {
                        Button("上一步") {
                            withAnimation(AppMotion.standard) {
                                step = previousStep
                            }
                        }
                        .buttonStyle(AppSheetSecondaryButtonStyle())
                    }

                    Button {
                        performPrimaryAction()
                    } label: {
                        Label(primaryActionTitle, systemImage: primaryActionIcon)
                    }
                    .buttonStyle(AppSheetPrimaryButtonStyle())
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppColors.refCardBg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppColors.refCardBorder, lineWidth: 1))
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
            case .url:
                urlConfiguration
            case .network:
                networkConfiguration
            case .emby, .jellyfin, .plex, .mlink:
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
                AppGlyph(systemImage: kind.systemImage, size: 19)
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
            AppSheetSection(title: "选择文件夹", systemImage: "folder.badge.plus", subtitle: "选择要接入的本地文件夹，可多选。") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            chooseLocalDirectories()
                        } label: {
                            Label(selectedURLs.isEmpty ? "选择文件夹" : "重新选择文件夹", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight, prominent: selectedURLs.isEmpty))

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
                        .staticSurfaceBackground(cornerRadius: AppRadius.card, shadowed: false)
                    }
                }
            }

            AppSheetSection(title: "分类", systemImage: "square.grid.2x2", subtitle: "决定内容归入哪个媒体库分类。") {
                MediaTypeGridPicker(selection: $mediaType, mediaTypes: mediaTypes, vaultName: vaultName, showsCard: false)
            }

            AppInfoNote(text: "添加后会立即进入扫描队列；更多参与策略会在下一步确认。", systemImage: "arrow.clockwise")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var networkConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSheetSection(title: "网络地址", systemImage: "network", subtitle: "填写共享地址和登录方式。") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("smb://nas.local/Media 或 ftp://192.168.1.10/Movies", text: $networkURL)
                        .glassFormField()

                    Toggle("匿名登录", isOn: $networkAnonymous.animation(AppMotion.fast))
                        .toggleStyle(AppSwitchToggleStyle())

                    if !networkAnonymous {
                        TextField("用户名", text: $networkUsername)
                            .glassFormField()
                        SecureField("密码", text: $networkPassword)
                            .glassFormField()
                    }
                }
            }

            AppSheetSection(title: "分类", systemImage: "square.grid.2x2", subtitle: "决定内容归入哪个媒体库分类。") {
                MediaTypeGridPicker(selection: $mediaType, mediaTypes: mediaTypes, vaultName: vaultName, showsCard: false)
            }

            AppInfoNote(text: "MediaLIB 会先让 macOS 打开网络位置，再从已挂载目录中选择真实扫描路径。参与策略会在下一步确认。", systemImage: "externaldrive.connected.to.line.below")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var urlConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSheetSection(title: "视频地址", systemImage: "link", subtitle: "支持直链视频地址，名称可选填。") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("https://example.com/video.mp4 或 rtsp://…", text: $urlInput)
                        .glassFormField()
                    TextField("名称（留空则自动取文件名）", text: $urlTitleInput)
                        .glassFormField()
                }
            }

            AppInfoNote(text: "添加后会出现在「其他视频」分类，与本地视频一致支持播放、下载和封面管理。多个地址会合并到同一个 URL 媒体源，可在媒体源行的「管理」中增删改查。", systemImage: "link")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var remoteConfiguration: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSheetSection(title: "服务器连接", systemImage: "server.rack", subtitle: "填写服务器地址和登录凭据。") {
                VStack(alignment: .leading, spacing: 12) {
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
                }
            }

            AppInfoNote(text: credentialNote, systemImage: "lock")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wizardSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppSheetSection(title: "参与策略", systemImage: "slider.horizontal.3", subtitle: "控制此媒体源是否参与元数据拉取、健康检查和同步。") {
                SourceBehaviorSettingsPanel(
                    isRemoteMediaServer: selectedKind.isRemoteMediaServer,
                    mediaType: mediaType,
                    includeInMetadataFetch: $includeInMetadataFetch,
                    includeInHealthCheck: $includeInHealthCheck,
                    preferMetadataWriteToSource: $preferMetadataWriteToSource,
                    remoteTraceSyncMode: $remoteTraceSyncMode
                )
            }

            AppInfoNote(text: selectedKind.isRemoteMediaServer ? "这些设置会随远程媒体源一起保存，后续可在媒体源行的设置按钮中修改。" : "这些设置会随目录媒体源一起保存，后续可在媒体源行的设置按钮中修改。", systemImage: "slider.horizontal.3")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        switch selectedKind {
        case .plex:
            return "服务器地址，例如 http://192.168.1.20:32400"
        case .mlink:
            return "服务器地址，例如 https://media.example.com（局域网非回环地址需 HTTPS）"
        default:
            return "服务器地址，例如 http://192.168.1.20:8096"
        }
    }

    private var credentialNote: String {
        if selectedKind == .plex {
            return "Plex Token 只保存在本机，用于后续自动同步。MediaLIB 不会使用系统钥匙串。"
        }
        if selectedKind == .mlink {
            return "登录密码只用于本次换取 Mlink 会话；access / refresh token 以受限本机文件保存，绝不会加入播放链接。非回环服务器必须使用 HTTPS。"
        }
        return "登录信息只保存在本机，用于后续自动同步。MediaLIB 不会使用系统钥匙串。"
    }

    private var primaryActionTitle: String {
        switch step {
        case .source:
            return "下一步"
        case .configure:
            return selectedKind == .url ? "添加视频" : "下一步"
        case .settings:
            switch selectedKind {
            case .local:
                return "添加并扫描"
            case .url:
                return "添加视频"
            case .network:
                return "连接并选择目录"
            case .plex:
                return appState.isConnectingPlex ? "Plex 连接中" : "连接并同步"
            case .mlink:
                return appState.isConnectingMlink ? "MediaLIB Server 连接中" : "登录并同步"
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
            return selectedKind == .url ? "plus" : "chevron.right"
        case .settings:
            switch selectedKind {
            case .local:
                return "folder.badge.plus"
            case .url:
                return "plus"
            case .network:
                return "network"
            case .emby, .jellyfin, .plex, .mlink:
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
            case .url:
                return appState.normalizedURLSourceString(urlInput) == nil
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
            case .mlink:
                return appState.isConnectingMlink
                    || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .settings:
            switch selectedKind {
            case .local:
                return selectedURLs.isEmpty
            case .url:
                return appState.normalizedURLSourceString(urlInput) == nil
            case .network:
                return networkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .plex:
                return appState.isConnectingPlex
            case .emby:
                return appState.isConnectingEmby
            case .jellyfin:
                return appState.isConnectingJellyfin
            case .mlink:
                return appState.isConnectingMlink
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
            // URL 视频没有参与策略，直接提交，不进入设置步骤。
            if selectedKind == .url {
                submitConfiguredSource()
            } else {
                withAnimation(AppMotion.standard) {
                    step = .settings
                }
            }
        case .settings:
            submitConfiguredSource()
        }
    }

    private func submitConfiguredSource() {
        switch selectedKind {
        case .url:
            let url = urlInput
            let title = urlTitleInput
            if appState.addURLVideo(urlString: url, title: title) {
                dismiss()
            }
        case .local:
            let urls = selectedURLs
            let type = mediaType
            // 相册与其他视频不参与元数据拉取。
            let includeMetadata = (type == .photo || type == .homeVideo) ? false : includeInMetadataFetch
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
        case .mlink:
            connectRemoteMediaServer(provider: .mlink)
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
            case .mlink:
                await appState.connectMlinkServer(
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
            includeMetadata: (mediaType == .photo || mediaType == .homeVideo) ? false : includeInMetadataFetch,
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
    case url
    case network
    case emby
    case jellyfin
    case plex
    case mlink

    var id: String { rawValue }

    var isRemoteMediaServer: Bool {
        switch self {
        case .emby, .jellyfin, .plex, .mlink:
            return true
        case .local, .url, .network:
            return false
        }
    }

    var title: String {
        switch self {
        case .local:
            return "本地目录"
        case .url:
            return "网络视频地址"
        case .network:
            return "网络设备"
        case .emby:
            return "Emby"
        case .jellyfin:
            return "Jellyfin"
        case .plex:
            return "Plex"
        case .mlink:
            return "MediaLIB Server"
        }
    }

    var detail: String {
        switch self {
        case .local:
            return "本机硬盘、移动硬盘或已挂载目录"
        case .url:
            return "粘贴 http/rtsp 等直链视频地址"
        case .network:
            return "SMB、FTP 或 FTPS 挂载后扫描"
        case .emby:
            return "登录服务器并同步媒体库"
        case .jellyfin:
            return "登录服务器并同步媒体库"
        case .plex:
            return "服务器地址与 Token 直连"
        case .mlink:
            return "安全登录并镜像服务端分类"
        }
    }

    var configureSubtitle: String {
        switch self {
        case .local:
            return "选择文件夹并指定分类。"
        case .url:
            return "粘贴视频直链并命名。"
        case .network:
            return "填写网络地址，挂载后选择实际目录。"
        case .emby:
            return "登录后同步到独立的 EMBY 目录。"
        case .jellyfin:
            return "登录后同步到独立的 Jellyfin 目录。"
        case .plex:
            return "连接后同步到独立的 Plex 目录。"
        case .mlink:
            return "登录后镜像服务端分类到独立的 Mlink 目录。"
        }
    }

    var systemImage: String {
        switch self {
        case .local:
            return "externaldrive.badge.plus"
        case .url:
            return "link"
        case .network:
            return "network"
        case .emby:
            return "server.rack"
        case .jellyfin:
            return "externaldrive.connected.to.line.below"
        case .plex:
            return "play.rectangle.on.rectangle"
        case .mlink:
            return "server.rack"
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
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .homeVideo, .music, .photo, .other, .privateCollection
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
                        AppSheetSection(title: "同步库", systemImage: "server.rack", subtitle: remoteLibrarySummary) {
                            remoteLibrarySection
                        }
                    } else {
                        AppSheetSection(title: "分类", systemImage: "square.grid.2x2", subtitle: "决定内容归入哪个媒体库分类。") {
                            MediaTypeGridPicker(selection: mediaTypeBinding, mediaTypes: mediaTypes, vaultName: appState.settings.privacyVaultName, showsCard: false)
                        }
                    }

                    AppSheetSection(title: "参与策略", systemImage: "slider.horizontal.3", subtitle: "控制此媒体源是否参与元数据拉取、健康检查和同步。") {
                        SourceBehaviorSettingsPanel(
                            isRemoteMediaServer: source.sourceKind.isRemoteMediaServer,
                            mediaType: draft.mediaType,
                            includeInMetadataFetch: includeInMetadataFetchBinding,
                            includeInHealthCheck: includeInHealthCheckBinding,
                            preferMetadataWriteToSource: preferMetadataWriteToSourceBinding,
                            remoteTraceSyncMode: remoteTraceSyncModeBinding
                        )
                    }

                    AppInfoNote(text: "保存只更新 MediaLIB 内部媒体源设置；不会移动、删除或重命名媒体文件。", systemImage: "checkmark.shield", shadowed: false)
                }
                // ScrollView 默认按自身 frame 边界硬裁切内容——卡片投影(radius14/y6)若净空不够，
                // 底部就会被切成一条直角硬边（本弹窗"非柔和阴影"根因之一）。上下各留够净空。
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: 520)
            .scrollContentBackground(.hidden)

            AppSheetActionFooter {
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(AppSheetSecondaryButtonStyle())

                Button {
                    save()
                } label: {
                    Label(isSaving ? "保存中" : saveTitle, systemImage: "checkmark")
                }
                .buttonStyle(AppSheetPrimaryButtonStyle())
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

    // 标题/概要已交给外层 AppSheetSection 卡头；这里只保留内容本身，且内部行统一
    // shadowed:false——嵌套在同一张卡片里，避免多层各自投影叠加发闷发硬（非柔和阴影）。
    private var remoteLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .staticSurfaceBackground(selected: syncAll, cornerRadius: 14, shadowed: false)
                .pointerLiquidEdge(cornerRadius: 14, intensity: 0.82)
            }
            .buttonStyle(.plain)

            remoteLibraryList
        }
    }

    @ViewBuilder
    private var remoteLibraryList: some View {
        if isLoadingLibraries {
            ProgressView("正在读取服务器媒体库…")
                .frame(maxWidth: .infinity, minHeight: 130)
                .staticSurfaceBackground(cornerRadius: AppRadius.card, shadowed: false)
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
            .staticSurfaceBackground(cornerRadius: AppRadius.card, shadowed: false)
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
            .staticSurfaceBackground(selected: isSelected && !syncAll, cornerRadius: 12, thickness: 0.94, shadowed: false)
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
        // 相册与其他视频不参与元数据拉取，保存时强制关闭，避免隐藏开关后仍标记为参与。
        if !source.sourceKind.isRemoteMediaServer,
           updated.mediaType == .photo || updated.mediaType == .homeVideo {
            updated.includeInMetadataFetch = false
        }
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
        case "homevideos": return "其他视频"
        case "photos": return "照片"
        case "livetv": return "电视直播"
        case .some(let value) where !value.isEmpty: return value
        default: return "混合媒体库"
        }
    }
}

private struct SourceBehaviorSettingsPanel: View {
    let isRemoteMediaServer: Bool
    /// 本地源的分类；相册（.photo）和其他视频（.homeVideo）不展示元数据拉取相关选项。
    var mediaType: MediaType = .auto
    @Binding var includeInMetadataFetch: Bool
    @Binding var includeInHealthCheck: Bool
    @Binding var preferMetadataWriteToSource: Bool
    @Binding var remoteTraceSyncMode: RemoteTraceSyncMode

    /// 相册与其他视频不参与元数据拉取，隐藏相关开关。
    private var showsMetadataParticipation: Bool {
        if isRemoteMediaServer { return true }
        return mediaType != .photo && mediaType != .homeVideo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                if showsMetadataParticipation {
                    Toggle("参与元数据拉取", isOn: Binding(
                        get: { includeInMetadataFetch },
                        set: { newValue in
                            includeInMetadataFetch = newValue
                            if !newValue {
                                preferMetadataWriteToSource = false
                            }
                        }
                    ))
                    .toggleStyle(AppSwitchToggleStyle())
                }
                Toggle("参与健康检查", isOn: $includeInHealthCheck)
                    .toggleStyle(AppSwitchToggleStyle())
                if !isRemoteMediaServer && showsMetadataParticipation {
                    Toggle("元数据优先写入源目录", isOn: $preferMetadataWriteToSource)
                        .toggleStyle(AppSwitchToggleStyle())
                        .disabled(!includeInMetadataFetch)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: 16, shadowed: false)

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
                .staticSurfaceBackground(cornerRadius: 16, shadowed: false)
            }
        }
    }
}

private struct MediaTypeGridPicker: View {
    @Binding var selection: MediaType
    let mediaTypes: [MediaType]
    let vaultName: String
    /// 已被外层 AppSheetSection 卡片包裹时传 false，避免卡中卡（双重白底+双重投影）。
    var showsCard: Bool = true

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        let grid = LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
            ForEach(mediaTypes, id: \.self) { type in
                Button {
                    withAnimation(AppMotion.fast) {
                        selection = type
                    }
                } label: {
                    GlassCapsuleControl(isSelected: selection == type, height: 30, horizontalPadding: 10, enablePointerEdge: false, expandHorizontally: true) {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: icon(for: type))
                            Text(title(for: type))
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .buttonStyle(.plain)
                .help(title(for: type))
            }
        }
        if showsCard {
            grid
                .padding(10)
                .staticSurfaceBackground(cornerRadius: 16)
        } else {
            grid
        }
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
        case .homeVideo: return "video"
        case .music: return "music.note"
        case .other: return "tray"
        case .privateCollection: return "lock"
        case .episode: return "list.number"
        case .photo: return "photo.on.rectangle.angled"
        }
    }
}

struct SourceRowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let source: MediaSource
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var showingSettings = false
    @State private var showingURLManager = false

    private var isURLSource: Bool { source.sourceKind == .url }

    var body: some View {
        let isLockedPrivateSource = source.mediaType == .privateCollection && !appState.privacyUnlocked
        let isReachable = appState.sourceIsReachable(source)
        let accent = sourceAccent(isReachable: isReachable)

        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(isReachable ? 1.0 : 0.92),
                                accent.opacity(isReachable ? 0.78 : 0.66)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.24 : 0.42), lineWidth: 1)
                AppGlyph(systemImage: iconName, size: 25)
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .compositingGroup()
            .shadow(color: accent.opacity(isReachable ? 0.30 : 0.14), radius: 16, x: -5, y: 8)
            .shadow(color: AppColors.referenceBlue.opacity(isReachable ? 0.16 : 0.08), radius: 10, x: 5, y: -4)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(sourceTitle(isLockedPrivateSource: isLockedPrivateSource))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppColors.textPrimary)

                    if isURLSource {
                        let unhealthy = appState.unhealthyURLItems.count
                        AppStatusBadge(
                            title: unhealthy == 0 ? "链接正常" : "\(unhealthy) 个链接失效",
                            systemImage: unhealthy == 0 ? "checkmark.circle" : "exclamationmark.circle",
                            tint: unhealthy == 0 ? AppColors.semanticGood : AppColors.semanticWarning
                        )
                    } else {
                        AppStatusBadge(
                            title: isReachable ? "可访问" : "不可访问",
                            systemImage: isReachable ? "checkmark.circle" : "exclamationmark.circle",
                            tint: isReachable ? AppColors.semanticGood : AppColors.semanticWarning
                        )
                    }

                    AppStatusBadge(
                        title: source.sourceKind.displayName,
                        systemImage: sourceKindBadgeIcon,
                        tint: accent
                    )
                }
                if isLockedPrivateSource {
                    Text("路径已隐藏，解锁\(appState.settings.privacyVaultName)后可查看。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if isURLSource {
                    Text("\(appState.urlSourceItems.count) 个视频地址 · 在「其他视频」中查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    // 路径过长时截断；鼠标悬停在该行时循环滚动完整路径。
                    MarqueeText(text: source.displayPath, font: .caption)
                        .frame(height: 15)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                if isURLSource {
                    Button {
                        showingURLManager = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(SubtleIconButtonStyle(minSize: 34))
                    .help("管理 URL 视频地址")
                    .accessibilityLabel("管理 URL 视频地址")
                } else {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.textSecondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(SubtleIconButtonStyle(minSize: 34))
                    .help("设置")
                    .accessibilityLabel("设置")

                    if !isReachable, appState.canRemountNetworkSource(source) {
                        Button {
                            appState.remountNetworkSource(source)
                        } label: {
                            AppGlyph(systemImage: "arrow.triangle.2.circlepath", size: 18)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(SubtleIconButtonStyle(minSize: 34))
                        .help("重新挂载")
                        .accessibilityLabel("重新挂载")
                    }

                    Button {
                        appState.scan(source)
                    } label: {
                        AppGlyph(systemImage: "arrow.clockwise", size: 18)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(SubtleIconButtonStyle(minSize: 34))
                    .disabled(appState.isScanning || !isReachable)
                    .help("扫描")
                    .accessibilityLabel("扫描")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.42))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(SubtleIconButtonStyle(minSize: 34))
                .help("删除")
                .accessibilityLabel("删除")
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
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .staticSurfaceBackground(selected: isHovering && !suppressHoverDuringScroll, cornerRadius: 16)
        // 系统页面/首页一致：媒体源卡片常态平铺，悬停时才上浮和浮出柔影。
        .shadow(
            color: AppColors.refCardShadow.opacity(isHovering && !suppressHoverDuringScroll ? 0.18 : 0),
            radius: isHovering && !suppressHoverDuringScroll ? 22 : 0,
            x: 0,
            y: isHovering && !suppressHoverDuringScroll ? 8 : 0
        )
        .offset(y: !reduceMotion && isHovering && !suppressHoverDuringScroll ? -4 : 0)
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
        .sheet(isPresented: $showingURLManager) {
            URLSourceManagementSheet()
                .environmentObject(appState)
        }
    }

    private var sourceKindBadgeIcon: String {
        switch source.sourceKind {
        case .emby, .jellyfin, .plex, .mlink:
            return "server.rack"
        case .local:
            return "internaldrive"
        case .url:
            return "link"
        case .smb, .ftp:
            return "network"
        }
    }

    private var iconName: String {
        if !appState.sourceIsReachable(source) {
            return "exclamationmark.triangle"
        }
        switch source.sourceKind {
        case .emby, .jellyfin, .plex, .mlink:
            return "server.rack"
        case .smb, .ftp:
            return "network"
        case .url:
            return "link"
        case .local:
            return "internaldrive"
        }
    }

    private func sourceAccent(isReachable: Bool) -> Color {
        guard isReachable else { return AppColors.semanticWarning }
        if source.mediaType == .privateCollection {
            return Color(red: 1.0, green: 0.36, blue: 0.54)
        }
        switch source.sourceKind {
        case .emby:
            return Color(red: 0.13, green: 0.83, blue: 0.66)
        case .jellyfin:
            return Color(red: 0.85, green: 0.27, blue: 0.94)
        case .plex:
            return AppColors.semanticWarning
        case .mlink:
            return Color(red: 0.15, green: 0.54, blue: 0.95)
        case .smb, .ftp:
            return AppColors.referenceCyan
        case .url:
            return Color(red: 0.13, green: 0.83, blue: 0.66)
        case .local:
            switch source.mediaType {
            case .music:
                return AppColors.semanticWarning
            case .photo, .homeVideo:
                return AppColors.referenceCyan
            default:
                return AppColors.referenceBlue
            }
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

// MARK: - URL 媒体源管理（增删改查）

private struct URLSourceManagementSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newURL = ""
    @State private var newTitle = ""
    @State private var editingItemID: String?
    @State private var editURL = ""
    @State private var editTitle = ""
    @State private var pendingDeleteID: String?

    private var items: [MediaItem] { appState.urlSourceItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSheetHeader(
                title: "URL 媒体源",
                subtitle: "管理网络视频地址，增删改查会同步到「其他视频」分类。",
                systemImage: "link"
            )

            addForm

            if items.isEmpty {
                EmptyStateView(
                    title: "还没有 URL 视频",
                    systemImage: "link.badge.plus",
                    message: "在上方粘贴 http/rtsp 等直链地址即可添加。"
                )
                .frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 320)
                .scrollContentBackground(.hidden)
            }

            AppSheetActionFooter {
                Button {
                    appState.refreshURLSourceHealth()
                } label: {
                    Label("重新检查链接", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(AppSheetSecondaryButtonStyle())
                .disabled(items.isEmpty)

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(AppSheetPrimaryButtonStyle())
            }
        }
        .appSheetChrome(width: AppSheetMetrics.wideWidth, maxHeight: 720)
        .onAppear {
            appState.refreshURLSourceHealth()
        }
    }

    @ViewBuilder
    private func healthDot(for item: MediaItem) -> some View {
        let state = appState.urlItemHealthState(for: item)
        let tint: Color = {
            switch state {
            case .ok: return AppColors.semanticGood
            case .unreachable: return AppColors.semanticWarning
            case .unparseable: return AppColors.semanticWarning
            case .checking, .unknown: return .secondary
            }
        }()
        Image(systemName: state.systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .help(state.displayName)
            .accessibilityLabel(state.displayName)
    }

    private var addForm: some View {
        let addableCount = appState.addableURLCount(in: newURL)
        let isBatch = addableCount > 1
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("添加地址")
            TextField("https://example.com/video.mp4 或 rtsp://…（每行一个可批量添加）", text: $newURL, axis: .vertical)
                .lineLimit(1...5)
                .glassFormField()
            if !isBatch {
                TextField("名称（可选，留空则取文件名）", text: $newTitle)
                    .glassFormField()
            }
            HStack {
                if isBatch {
                    Text("检测到 \(addableCount) 个链接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    let added: Bool
                    if isBatch {
                        added = appState.addURLVideos(fromMultiline: newURL) > 0
                    } else {
                        added = appState.addURLVideo(urlString: newURL, title: newTitle)
                    }
                    if added {
                        newURL = ""
                        newTitle = ""
                    }
                } label: {
                    Label(isBatch ? "批量添加 \(addableCount) 个" : "添加", systemImage: "plus")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: AppControlMetrics.defaultButtonHeight, prominent: true))
                .disabled(addableCount == 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: 16)
    }

    @ViewBuilder
    private func row(_ item: MediaItem) -> some View {
        if editingItemID == item.id {
            VStack(alignment: .leading, spacing: 10) {
                TextField("视频地址", text: $editURL)
                    .glassFormField()
                TextField("名称", text: $editTitle)
                    .glassFormField()
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("取消") {
                        editingItemID = nil
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight))
                    Button {
                        if appState.updateURLVideo(item, urlString: editURL, title: editTitle) {
                            editingItemID = nil
                        }
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 12, minHeight: AppControlMetrics.defaultButtonHeight, prominent: true))
                    .disabled(appState.normalizedURLSourceString(editURL) == nil)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(selected: true, cornerRadius: 14)
        } else {
            HStack(spacing: 12) {
                PosterImage(path: item.posterPath, title: item.title, mediaType: .homeVideo, cacheTargetSize: CGSize(width: 128, height: 80))
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        healthDot(for: item)
                    }
                    Text(item.filePath ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    if appState.canCaptureVideoCover(for: item) {
                        Button {
                            appState.captureVideoCover(for: item)
                        } label: {
                            Label("从视频截取封面", systemImage: "camera.viewfinder")
                        }
                    }
                    Button {
                        appState.chooseCustomArtwork(for: item, kind: .poster)
                    } label: {
                        Label("选择自定义封面…", systemImage: "photo.badge.plus")
                    }
                } label: {
                    AppGlyph(systemImage: "photo", size: 18)
                        .frame(width: 18, height: 18)
                }
                .menuIndicator(.hidden)
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: AppControlMetrics.defaultButtonHeight, thickness: 0.96))
                .fixedSize()
                .help("封面")

                Button {
                    editURL = item.filePath ?? ""
                    editTitle = item.title
                    editingItemID = item.id
                } label: {
                    AppGlyph(systemImage: "pencil", size: 18)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: AppControlMetrics.defaultButtonHeight, thickness: 0.96))
                .help("编辑")

                Button(role: .destructive) {
                    pendingDeleteID = item.id
                } label: {
                    AppGlyph(systemImage: "trash", size: 18)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.red)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: AppControlMetrics.defaultButtonHeight, thickness: 0.96))
                .help("删除")
                .confirmationDialog(
                    "删除「\(item.title)」？",
                    isPresented: Binding(
                        get: { pendingDeleteID == item.id },
                        set: { if !$0 { pendingDeleteID = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        appState.removeURLVideos(ids: [item.id])
                        pendingDeleteID = nil
                    }
                    Button("取消", role: .cancel) { pendingDeleteID = nil }
                } message: {
                    Text("将从「其他视频」移除该地址；已下载到本机的文件不会被删除。")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .staticSurfaceBackground(cornerRadius: AppRadius.card)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
    }
}
