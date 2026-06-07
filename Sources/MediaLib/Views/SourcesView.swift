import AppKit
import MediaLibCore
import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingSourceURLs: [URL] = []
    @State private var typeSelectionRequest: SourceTypeSelectionRequest?
    @State private var showingEmbySheet = false
    @State private var showingNetworkSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "媒体源",
                    subtitle: "管理本地文件夹、移动硬盘、网络挂载和 Emby 媒体库。",
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
                        message: "接入本地文件夹、移动硬盘、网络挂载或 Emby 媒体库后，MediaLIB 会整理索引。"
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
                key: "sources.emby.rename.context",
                message: "EMBY 来源名称不合适时，可以在左侧栏右键它来重命名。"
            )
        }
        .sheet(item: $typeSelectionRequest, onDismiss: {
            pendingSourceURLs = []
        }) { request in
            MediaSourceTypeSelectionSheet(
                urls: request.urls,
                vaultName: appState.settings.privacyVaultName
            ) { mediaType in
                addPendingSources(as: mediaType)
            } onCancel: {
                pendingSourceURLs = []
                typeSelectionRequest = nil
            }
        }
        .sheet(isPresented: $showingEmbySheet) {
            EmbyLoginSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingNetworkSheet) {
            NetworkMediaSourceSheet(vaultName: appState.settings.privacyVaultName)
                .environmentObject(appState)
        }
    }

    private func chooseMediaSource() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            pendingSourceURLs = panel.urls
            typeSelectionRequest = SourceTypeSelectionRequest(urls: panel.urls)
        }
    }

    private func addPendingSources(as mediaType: MediaType) {
        let urls = pendingSourceURLs
        pendingSourceURLs = []
        typeSelectionRequest = nil
        appState.addSources(urls: urls, mediaType: mediaType)
    }

    private static let addableMediaTypes: [MediaType] = [
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection
    ]

    private var sourceActionsToolbar: some View {
        AppSurfaceToolbar {
            Button {
                chooseMediaSource()
            } label: {
                Label("添加…", systemImage: "plus")
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32, prominent: true))

            Button {
                showingEmbySheet = true
            } label: {
                Label(appState.isConnectingEmby ? "Emby 连接中" : "Emby 登录…", systemImage: "server.rack")
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))
            .disabled(appState.isConnectingEmby)

            Button {
                showingNetworkSheet = true
            } label: {
                Label("网络设备…", systemImage: "network")
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))

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

private struct EmbyLoginSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSheetHeader(
                title: "连接 Emby",
                subtitle: "登录后，媒体库会在后台同步到独立的 EMBY 目录。",
                systemImage: "server.rack"
            )

            TextField("服务器地址，例如 http://192.168.1.20:8096", text: $server)
                .glassFormField()

            TextField("用户名", text: $username)
                .glassFormField()

            SecureField("密码", text: $password)
                .glassFormField()

            AppInfoNote(text: "登录信息只保存在本机，用于后续自动同步。MediaLIB 不会使用系统钥匙串。", systemImage: "lock")

            AppSheetActionFooter {
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                Button("登录并同步") {
                    let request = (server: server, username: username, password: password)
                    dismiss()
                    Task {
                        await Task.yield()
                        await appState.connectEmbyServer(
                            server: request.server,
                            username: request.username,
                            password: request.password
                        )
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.wideWidth)
    }
}

private struct NetworkMediaSourceSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let vaultName: String
    @State private var networkURL = "smb://"
    @State private var username = ""
    @State private var password = ""
    @State private var anonymous = true
    @State private var mediaType: MediaType = .auto

    private let mediaTypes: [MediaType] = [.auto, .movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSheetHeader(
                title: "添加网络设备",
                subtitle: "支持 SMB、FTP 和 FTPS。连接后选择挂载目录与媒体分类。",
                systemImage: "network"
            )

            TextField("smb://nas.local/Media 或 ftp://192.168.1.10/Movies", text: $networkURL)
                .glassFormField()

            Toggle("匿名登录", isOn: $anonymous)

            if !anonymous {
                TextField("用户名", text: $username)
                    .glassFormField()
                SecureField("密码", text: $password)
                    .glassFormField()
            }

            MediaTypeGridPicker(selection: $mediaType, mediaTypes: mediaTypes, vaultName: vaultName)

            AppInfoNote(text: "macOS 负责登录和挂载；MediaLIB 从选中的目录扫描内容。", systemImage: "externaldrive.connected.to.line.below")

            AppSheetActionFooter {
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                Button("连接并选择目录") {
                    connectAndPickDirectory()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(networkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.wideWidth)
    }

    private func connectAndPickDirectory() {
        guard let url = credentialURL else {
            appState.alert = AppAlert(title: "网络地址无效", message: "地址需以 smb://、ftp:// 或 ftps:// 开头。")
            return
        }
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
                    networkURL: networkURL,
                    mountedDirectory: mountedURL,
                    username: anonymous ? nil : username,
                    password: anonymous ? nil : password,
                    mediaType: mediaType
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
        if !anonymous {
            components.user = username.isEmpty ? nil : username
            components.password = password.isEmpty ? nil : password
        }
        return components.url
    }
}

private struct SourceTypeSelectionRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct MediaSourceTypeSelectionSheet: View {
    let urls: [URL]
    let vaultName: String
    let onSelect: (MediaType) -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]
    private let mediaTypes: [MediaType] = [
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "选择媒体源分类",
                subtitle: sourceSummary,
                systemImage: "folder.badge.plus",
                subtitleLineLimit: 1,
                truncationMode: .middle
            )

            Text("选择该目录的媒体分类；添加后仍可在媒体源列表中修改。")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(mediaTypes, id: \.self) { type in
                    Button {
                        onSelect(type)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: icon(for: type))
                                .frame(width: 18)
                            Text(title(for: type))
                                .lineLimit(1)
                            Spacer()
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .staticSurfaceBackground(cornerRadius: 12, thickness: 0.94)
                        .pointerLiquidEdge(cornerRadius: 12, intensity: 0.88)
                    }
                    .buttonStyle(.plain)
                }
            }

            AppSheetActionFooter {
                Button("取消", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                .keyboardShortcut(.cancelAction)
            }
        }
        .appSheetChrome(width: AppSheetMetrics.standardWidth)
    }

    private var sourceSummary: String {
        if urls.count == 1 {
            return urls[0].lastPathComponent
        }
        return "已选择 \(urls.count) 个文件夹"
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

private struct MediaTypeGridPicker: View {
    @Binding var selection: MediaType
    let mediaTypes: [MediaType]
    let vaultName: String

    private let columns = [GridItem(.adaptive(minimum: 124), spacing: 8)]

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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// 媒体源行内同类下拉框的统一宽度，保证各行对齐。
private enum SourceRowMetrics {
    static let typeMenuWidth: CGFloat = 118
    static let participationMenuWidth: CGFloat = 168
}

struct SourceRowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let source: MediaSource
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

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
                if source.sourceKind == .emby {
                    GlassMenuButton(title: "EMBY", width: SourceRowMetrics.typeMenuWidth) {
                        Button {
                        } label: {
                            Label("EMBY", systemImage: "server.rack")
                        }
                        .disabled(true)
                    }
                } else {
                    GlassMenuButton(title: title(for: source.mediaType), width: SourceRowMetrics.typeMenuWidth) {
                        ForEach(Self.mediaTypes, id: \.self) { mediaType in
                            Button {
                                var updated = source
                                updated.mediaType = mediaType
                                appState.updateSource(updated)
                            } label: {
                                Label(title(for: mediaType), systemImage: icon(for: mediaType))
                            }
                        }
                    }
                }

                GlassMenuButton(title: participationTitle, width: SourceRowMetrics.participationMenuWidth) {
                    Toggle("参与元数据拉取", isOn: Binding(
                        get: { source.includeInMetadataFetch },
                        set: { newValue in
                            var updated = source
                            updated.includeInMetadataFetch = newValue
                            if !newValue {
                                updated.preferMetadataWriteToSource = false
                            }
                            appState.updateSource(updated)
                        }
                    ))
                    Toggle("参与健康检查", isOn: Binding(
                        get: { source.includeInHealthCheck },
                        set: { newValue in
                            var updated = source
                            updated.includeInHealthCheck = newValue
                            appState.updateSource(updated)
                        }
                    ))
                    if source.sourceKind != .emby {
                        Toggle("元数据优先写入源目录", isOn: Binding(
                            get: { source.preferMetadataWriteToSource },
                            set: { newValue in
                                var updated = source
                                updated.preferMetadataWriteToSource = newValue
                                appState.updateSource(updated)
                            }
                        ))
                        .disabled(!source.includeInMetadataFetch)
                    } else {
                        Divider()
                        Picker("痕迹数据同步", selection: Binding(
                            get: { source.remoteTraceSyncMode },
                            set: { mode in
                                var updated = source
                                updated.remoteTraceSyncMode = mode
                                appState.updateSource(updated)
                            }
                        )) {
                            ForEach(RemoteTraceSyncMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        Text(source.remoteTraceSyncMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !isReachable {
                    Text("不可访问")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.orange)
                        .frame(width: 58, alignment: .trailing)
                }

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
                    "删除媒体源「\(source.name)」？",
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
    }

    private var participationTitle: String {
        if source.includeInMetadataFetch, source.preferMetadataWriteToSource, source.sourceKind != .emby {
            return "元数据写回优先"
        }
        if source.sourceKind == .emby {
            return source.remoteTraceSyncMode.shortTitle
        }
        switch (source.includeInMetadataFetch, source.includeInHealthCheck) {
        case (true, true): return "元数据与健康检查"
        case (true, false): return "仅元数据拉取"
        case (false, true): return "仅健康检查"
        case (false, false): return "不参与检查"
        }
    }

    private static let mediaTypes: [MediaType] = [
        .auto, .movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection
    ]

    private var iconName: String {
        if !appState.sourceIsReachable(source) {
            return "externaldrive.badge.exclamationmark"
        }
        switch source.sourceKind {
        case .emby:
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
        if source.sourceKind == .emby {
            return "EMBY"
        }
        return source.name
    }

    private func title(for type: MediaType) -> String {
        type == .privateCollection ? appState.settings.privacyVaultName : type.displayName
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
