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
                    subtitle: "为电影、电视剧、音乐和保险库目录分别设置类型，扫描会按目录类型稳定归档。",
                    systemImage: "externaldrive"
                )

                sourceActionsToolbar

                if let progress = appState.scanProgress, appState.isScanning {
                    ScanProgressView(progress: progress)
                }

                if appState.sources.isEmpty {
                    EmptyStateView(
                        title: "还没有媒体源",
                        systemImage: "externaldrive.badge.plus",
                        message: "添加本机文件夹、外接硬盘，或 `/Volumes` 下已挂载的 NAS 目录。"
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
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button {
                        chooseMediaSource()
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32, prominent: true))

                    Button {
                        showingEmbySheet = true
                    } label: {
                        Label("Emby 登录", systemImage: "server.rack")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 32))

                    Button {
                        showingNetworkSheet = true
                    } label: {
                        Label("网络设备", systemImage: "network")
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
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(shape)
            .staticSurfaceBackground(cornerRadius: 18, thickness: 1.04)
            .overlay {
                shape.stroke(.white.opacity(0.64), lineWidth: 0.7)
            }
    }
}

private struct EmbyLoginSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PlayfulSymbolIcon(systemImage: "server.rack", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接 Emby")
                        .font(.title3.weight(.semibold))
                    Text("登录后从 Emby API 获取资源，并按服务器分类同步到 EMBY 目录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("服务器地址，例如 http://192.168.1.20:8096", text: $server)
                .glassFormField()

            TextField("用户名", text: $username)
                .glassFormField()

            SecureField("密码", text: $password)
                .glassFormField()

            Text("MediaLIB 会把 Emby token 保存在本机凭据目录中，不会触碰系统钥匙串；导入条目会记录 Emby ItemId、分类 ViewId 和播放流地址，刷新时保持同一内部资源映射。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .staticSurfaceBackground(cornerRadius: 10, thickness: 0.86)

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                Button(isConnecting ? "连接中..." : "登录并同步") {
                    isConnecting = true
                    Task {
                        await appState.connectEmbyServer(server: server, username: username, password: password)
                        isConnecting = false
                        dismiss()
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(isConnecting || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(AppPageBackground())
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
            HStack(spacing: 12) {
                PlayfulSymbolIcon(systemImage: "network", size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加网络设备")
                        .font(.title3.weight(.semibold))
                    Text("支持 smb://、ftp://、ftps://。连接后选择挂载目录并指定分类。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

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

            Text("macOS 会负责 SMB/FTP 登录和挂载；选择目录后 MediaLIB 使用现有扫描器导入，之后可像本地媒体源一样重新扫描。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .staticSurfaceBackground(cornerRadius: 10, thickness: 0.86)

            HStack {
                Spacer()
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
        .padding(22)
        .frame(width: 620)
        .background(AppPageBackground())
    }

    private func connectAndPickDirectory() {
        guard let url = credentialURL else {
            appState.alert = AppAlert(title: "网络地址无效", message: "请输入 smb://、ftp:// 或 ftps:// 开头的地址。")
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
            HStack(spacing: 12) {
                PlayfulSymbolIcon(systemImage: "folder.badge.plus", size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("选择媒体源分类")
                        .font(.title3.weight(.semibold))
                    Text(sourceSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text("添加前先选择分类，MediaLIB 会按该分类扫描归档；之后仍可在媒体源列表中修改。")
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

            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(AppPageBackground())
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

struct SourceRowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let source: MediaSource
    @State private var isHovering = false

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
                Text(isLockedPrivateSource ? "路径已隐藏，解锁\(appState.settings.privacyVaultName)后可查看。" : source.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                if source.sourceKind == .emby {
                    GlassMenuButton(title: "EMBY", width: 128) {
                        Button {
                        } label: {
                            Label("EMBY", systemImage: "server.rack")
                        }
                        .disabled(true)
                    }
                } else {
                    GlassMenuButton(title: title(for: source.mediaType), width: 128) {
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

                if !isReachable {
                    Text("不可访问")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.orange)
                        .frame(width: 58, alignment: .trailing)
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
                    appState.deleteSource(source)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 32, thickness: 0.96))
                .help("删除")
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
