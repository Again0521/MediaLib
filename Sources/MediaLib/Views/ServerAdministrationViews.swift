import MediaLibCore
import SwiftUI

struct ServerInitialPasswordSetupSheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "设置服务端管理员密码",
                subtitle: "此密码用于网页和 Mlink 客户端登录 admin；MediaLIB 只保存 Argon2id 编码凭据。",
                systemImage: "person.badge.key"
            )

            AppSheetSection(
                title: "初始管理员",
                systemImage: "lock.shield",
                subtitle: "首次设置只能成功一次，完成后此入口会永久关闭。"
            ) {
                VStack(spacing: 14) {
                    SettingsRow(title: "新密码", systemImage: "key") {
                        SecureField("至少 12 个字符", text: $password)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 280)
                    }
                    SettingsRow(title: "确认密码", systemImage: "checkmark.shield") {
                        SecureField("再次输入", text: $confirmation)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 280)
                    }
                }
            }

            AppInfoNote(
                text: "密码必须为 12–1024 个 UTF-8 字节。建议使用由多个随机单词组成的长密码；请勿与其它网站共用。",
                systemImage: "checkmark.shield"
            )

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(AppSheetSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isWorking)
                Button(action: submit) {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                        Text("正在保护密码…")
                    } else {
                        Label("完成设置", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(AppSheetPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || store.isWorking)
            }
        }
        .appSheetChrome(width: 590)
        .interactiveDismissDisabled(store.isWorking)
        .onDisappear {
            password = ""
            confirmation = ""
            store.clearError()
        }
    }

    private var canSubmit: Bool {
        let byteCount = password.utf8.count
        return (12...1_024).contains(byteCount) && password == confirmation
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedPassword = password
        password = ""
        confirmation = ""
        Task { @MainActor in
            if await store.setInitialAdministratorPassword(submittedPassword) {
                onComplete()
            }
        }
    }
}

struct ServerAdministratorPasswordChangeSheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "修改服务端管理员密码",
                subtitle: "必须验证当前密码；完成后全部 Web 与 Mlink 会话会立即失效。",
                systemImage: "key.viewfinder"
            )

            AppSheetSection(title: "验证与轮换", systemImage: "lock.shield") {
                VStack(spacing: 14) {
                    SettingsRow(title: "当前密码", systemImage: "key") {
                        SecureField("输入当前密码", text: $currentPassword)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 300)
                    }
                    SettingsRow(title: "新密码", systemImage: "key.horizontal") {
                        SecureField("至少 12 个字符", text: $newPassword)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 300)
                    }
                    SettingsRow(title: "确认新密码", systemImage: "checkmark.shield") {
                        SecureField("再次输入", text: $confirmation)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 300)
                    }
                }
            }

            AppInfoNote(
                text: "新密码必须为 12–1024 个 UTF-8 字节，且不能与当前密码相同。提交时输入框会立即清空，数据库只保存新的 Argon2id 编码凭据。",
                systemImage: "checkmark.shield"
            )

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(AppSheetSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isWorking)
                Button(action: submit) {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                        Text("正在轮换凭据…")
                    } else {
                        Label("修改并退出全部会话", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(AppSheetPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || store.isWorking)
            }
        }
        .appSheetChrome(width: 620)
        .interactiveDismissDisabled(store.isWorking)
        .onDisappear {
            clearPasswords()
            store.clearError()
        }
    }

    private var canSubmit: Bool {
        let byteCount = newPassword.utf8.count
        return !currentPassword.isEmpty && currentPassword != newPassword &&
            (12...1_024).contains(byteCount) && newPassword == confirmation
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedCurrentPassword = currentPassword
        let submittedNewPassword = newPassword
        clearPasswords()
        Task { @MainActor in
            if await store.changeAdministratorPassword(
                currentPassword: submittedCurrentPassword,
                newPassword: submittedNewPassword
            ) {
                onComplete()
            }
        }
    }

    private func clearPasswords() {
        currentPassword = ""
        newPassword = ""
        confirmation = ""
    }
}

struct ServerAdministratorPasswordRecoverySheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let prepareForRecovery: @MainActor () async -> Bool
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var newPassword = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "恢复服务端管理员密码",
                subtitle: "仅限当前 Mac 本机操作，不会创建网页恢复地址或恢复 token。",
                systemImage: "person.badge.key.fill"
            )

            AppSheetSection(
                title: "本机安全恢复",
                systemImage: "touchid",
                subtitle: "提交后 macOS 会要求 Touch ID 或当前 Mac 的登录密码。"
            ) {
                VStack(spacing: 14) {
                    SettingsRow(title: "恢复密码", systemImage: "key.horizontal") {
                        SecureField("至少 12 个字符", text: $newPassword)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 300)
                    }
                    SettingsRow(title: "确认密码", systemImage: "checkmark.shield") {
                        SecureField("再次输入", text: $confirmation)
                            .textFieldStyle(.plain)
                            .glassFormField()
                            .frame(width: 300)
                    }
                }
            }

            AppInfoNote(
                text: "验证通过后会先关闭服务并取消自动启动，再原子替换管理员凭据、撤销全部旧设备和会话。恢复完成后服务不会自动重开。",
                systemImage: "exclamationmark.shield"
            )

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(AppSheetSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isWorking)
                Button(action: submit) {
                    if store.isWorking {
                        ProgressView().controlSize(.small)
                        Text("正在验证与恢复…")
                    } else {
                        Label("验证 Mac 身份并恢复", systemImage: "touchid")
                    }
                }
                .buttonStyle(AppSheetPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || store.isWorking)
            }
        }
        .appSheetChrome(width: 630)
        .interactiveDismissDisabled(store.isWorking)
        .onDisappear {
            clearPasswords()
            store.clearError()
        }
    }

    private var canSubmit: Bool {
        (12...1_024).contains(newPassword.utf8.count) && newPassword == confirmation
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedPassword = newPassword
        clearPasswords()
        Task { @MainActor in
            if await store.recoverAdministratorPassword(
                newPassword: submittedPassword,
                prepareForRecovery: prepareForRecovery
            ) {
                onComplete()
            }
        }
    }

    private func clearPasswords() {
        newPassword = ""
        confirmation = ""
    }
}

struct ServerSessionManagementSheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let onClose: () -> Void

    @State private var pendingAction: PendingAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "设备与登录会话",
                subtitle: "查看 admin 的活动设备，撤销遗失设备或让指定浏览器立即退出。",
                systemImage: "laptopcomputer.and.iphone"
            )

            HStack(spacing: 12) {
                summaryCard(title: "活动设备", value: store.activeDeviceCount, systemImage: "desktopcomputer")
                summaryCard(title: "登录会话", value: store.activeSessionCount, systemImage: "person.crop.circle.badge.checkmark")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    deviceSection
                    sessionSection
                }
            }
            .frame(maxHeight: 430)

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppSheetActionFooter {
                Button("刷新") {
                    Task { await store.refresh() }
                }
                .buttonStyle(AppSheetSecondaryButtonStyle())
                .disabled(store.isLoading || store.isWorking)

                Button("退出全部会话") {
                    pendingAction = .allSessions
                }
                .buttonStyle(AppSheetSecondaryButtonStyle())
                .disabled(store.activeSessionCount == 0 || store.isWorking)

                Button("完成", action: onClose)
                    .buttonStyle(AppSheetPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isWorking)
            }
        }
        .appSheetChrome(width: 720, minHeight: 560, maxHeight: 720)
        .interactiveDismissDisabled(store.isWorking)
        .task { await store.refresh() }
        .confirmationDialog(
            pendingAction?.title ?? "确认撤销",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingAction?.buttonTitle ?? "撤销", role: .destructive) {
                guard let action = pendingAction else { return }
                pendingAction = nil
                Task { await perform(action) }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    private var deviceSection: some View {
        AppSheetSection(
            title: "活动设备",
            systemImage: "desktopcomputer",
            subtitle: "撤销设备会同时撤销它的全部登录会话，且该设备必须重新登录。"
        ) {
            if let devices = store.snapshot?.devices, !devices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        administrationRow(
                            title: device.name,
                            detail: "\(device.platform) · 最近活动 \(formatted(device.lastSeenAt))",
                            systemImage: device.platform.lowercased().contains("web") ? "safari" : "desktopcomputer"
                        ) {
                            pendingAction = .device(id: device.id, name: device.name)
                        }
                        if index < devices.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
            } else {
                emptyState("暂无活动设备")
            }
        }
    }

    private var sessionSection: some View {
        AppSheetSection(
            title: "登录会话",
            systemImage: "person.crop.circle.badge.checkmark",
            subtitle: "会话列表不包含访问令牌、刷新令牌或其摘要。"
        ) {
            if let sessions = store.snapshot?.sessions, !sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        let deviceName = store.snapshot?.devices.first(where: { $0.id == session.deviceID })?.name
                            ?? "未知设备"
                        administrationRow(
                            title: deviceName,
                            detail: "最后使用 \(formatted(session.lastUsedAt)) · 刷新有效至 \(formatted(session.refreshExpiresAt))",
                            systemImage: "person.crop.circle"
                        ) {
                            pendingAction = .session(id: session.id, deviceName: deviceName)
                        }
                        if index < sessions.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
            } else {
                emptyState("暂无活动登录会话")
            }
        }
    }

    private func summaryCard(title: String, value: Int, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.referenceBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.title2.weight(.bold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, shadowed: false)
    }

    private func administrationRow(
        title: String,
        detail: String,
        systemImage: String,
        revoke: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 30, height: 30)
                .foregroundStyle(AppColors.referenceBlue)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("撤销", role: .destructive, action: revoke)
                .buttonStyle(.borderless)
                .disabled(store.isWorking)
        }
        .padding(.vertical, 9)
    }

    private func emptyState(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54)
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func perform(_ action: PendingAction) async {
        switch action {
        case let .device(id, _): await store.revokeDevice(id: id)
        case let .session(id, _): await store.revokeSession(id: id)
        case .allSessions: await store.revokeAllSessions()
        }
    }
}

private enum PendingAction: Identifiable {
    case device(id: String, name: String)
    case session(id: String, deviceName: String)
    case allSessions

    var id: String {
        switch self {
        case let .device(id, _): "device:\(id)"
        case let .session(id, _): "session:\(id)"
        case .allSessions: "all-sessions"
        }
    }

    var title: String {
        switch self {
        case let .device(_, name): "撤销设备“\(name)”？"
        case let .session(_, deviceName): "退出“\(deviceName)”的这个会话？"
        case .allSessions: "退出全部登录会话？"
        }
    }

    var message: String {
        switch self {
        case .device: "该设备的全部访问与刷新会话会立即失效，需要重新登录。"
        case .session: "这个登录会话的访问和刷新令牌会立即失效。"
        case .allSessions: "所有浏览器和 Mlink 客户端都会退出；桌面端本地管理不受影响。"
        }
    }

    var buttonTitle: String {
        switch self {
        case .device: "撤销设备"
        case .session: "退出会话"
        case .allSessions: "全部退出"
        }
    }
}

struct ServerLibraryOption: Identifiable, Equatable {
    let id: String
    let name: String
    let mediaType: MediaType
}

struct ServerUserManagementSheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let libraries: [ServerLibraryOption]
    let onClose: () -> Void

    @State private var selectedUserID: String?
    @State private var editingUser: ServerManagedUserSnapshot?
    @State private var isCreatingUser = false
    @State private var resettingUser: ServerManagedUserSnapshot?
    @State private var pendingSessionRevocation: ServerManagedUserSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "用户与访问权限",
                subtitle: "按用户分配角色和媒体库；权限或状态变更会立即撤销该用户的既有会话。",
                systemImage: "person.2.badge.gearshape"
            )

            HStack(alignment: .top, spacing: 16) {
                userList
                    .frame(width: 230)
                Divider()
                userDetail
                    .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
            }

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AppSheetActionFooter {
                Button("刷新") { Task { await store.refresh() } }
                    .buttonStyle(AppSheetSecondaryButtonStyle())
                    .disabled(store.isLoading || store.isWorking)
                Button("新建用户…") {
                    store.clearError()
                    isCreatingUser = true
                }
                .buttonStyle(AppSheetSecondaryButtonStyle())
                .disabled(store.isWorking || store.requiresInitialPassword)
                Button("完成", action: onClose)
                    .buttonStyle(AppSheetPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isWorking)
            }
        }
        .appSheetChrome(width: 900, minHeight: 650, maxHeight: 820)
        .interactiveDismissDisabled(store.isWorking)
        .task {
            await store.refresh()
            selectFirstUserIfNeeded()
        }
        .onChange(of: store.snapshot?.users.map(\.id) ?? []) { _ in
            selectFirstUserIfNeeded()
        }
        .sheet(isPresented: $isCreatingUser) {
            ServerUserEditorSheet(
                store: store,
                user: nil,
                libraries: libraries,
                onComplete: {
                    isCreatingUser = false
                    selectedUserID = store.snapshot?.users.last?.id
                },
                onCancel: { isCreatingUser = false }
            )
        }
        .sheet(item: $editingUser) { user in
            ServerUserEditorSheet(
                store: store,
                user: user,
                libraries: libraries,
                onComplete: { editingUser = nil },
                onCancel: { editingUser = nil }
            )
        }
        .sheet(item: $resettingUser) { user in
            ServerPasswordResetSheet(
                store: store,
                user: user,
                onComplete: { resettingUser = nil },
                onCancel: { resettingUser = nil }
            )
        }
        .confirmationDialog(
            "退出该用户的全部会话？",
            isPresented: Binding(
                get: { pendingSessionRevocation != nil },
                set: { if !$0 { pendingSessionRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("全部退出", role: .destructive) {
                guard let user = pendingSessionRevocation else { return }
                pendingSessionRevocation = nil
                Task { await store.revokeAllSessions(userID: user.id) }
            }
            Button("取消", role: .cancel) { pendingSessionRevocation = nil }
        } message: {
            Text("该用户的所有 Web 与 Mlink 登录都会立即失效，需要重新登录。")
        }
    }

    private var userList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("服务端用户").font(.headline)
            List(selection: $selectedUserID) {
                ForEach(store.snapshot?.users ?? []) { managed in
                    HStack(spacing: 10) {
                        Image(systemName: managed.roleID == ServerIdentityRepository.administratorRoleID
                            ? "person.badge.shield.checkmark" : "person.crop.circle")
                            .foregroundStyle(managed.user.isDisabled ? .secondary : AppColors.referenceBlue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(managed.user.displayName).lineLimit(1)
                            Text("@\(managed.user.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if managed.user.isDisabled {
                            Image(systemName: "nosign").foregroundStyle(AppColors.warning)
                        }
                    }
                    .tag(managed.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var userDetail: some View {
        if let managed = selectedUser {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(managed.user.displayName).font(.title2.weight(.semibold))
                            Text("@\(managed.user.username) · \(roleName(managed.roleID))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if managed.id != ServerIdentityRepository.initialAdministratorUserID {
                            Button("编辑权限…") {
                                store.clearError()
                                editingUser = managed
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack(spacing: 12) {
                        detailMetric("媒体库", value: managed.roleID == ServerIdentityRepository.administratorRoleID
                            ? libraries.count : managed.grants.filter(\.canView).count)
                        detailMetric("活动设备", value: managed.activeDeviceCount)
                        detailMetric("登录会话", value: managed.activeSessionCount)
                    }

                    AppSheetSection(
                        title: "媒体库访问",
                        systemImage: "rectangle.stack.badge.person.crop",
                        subtitle: managed.roleID == ServerIdentityRepository.administratorRoleID
                            ? "管理员可访问全部媒体源；保险库还需要在这台 Mac 上解锁。"
                            : "未列出的媒体库默认拒绝访问。"
                    ) {
                        grantRows(for: managed)
                    }

                    if managed.id != ServerIdentityRepository.initialAdministratorUserID {
                        AppSheetSection(
                            title: "账号安全",
                            systemImage: "lock.shield",
                            subtitle: "密码重置和会话撤销均会写入安全审计。"
                        ) {
                            HStack {
                                Button("重置密码…") { resettingUser = managed }
                                    .buttonStyle(.bordered)
                                Button("退出全部会话", role: .destructive) {
                                    pendingSessionRevocation = managed
                                }
                                .buttonStyle(.bordered)
                                .disabled(managed.activeSessionCount == 0)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    securityEvents
                }
                .padding(.trailing, 8)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("选择一个用户").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func grantRows(for managed: ServerManagedUserSnapshot) -> some View {
        let grants = managed.roleID == ServerIdentityRepository.administratorRoleID
            ? libraries.map { ($0, "查看 · 播放 · 下载 · 管理") }
            : libraries.compactMap { library -> (ServerLibraryOption, String)? in
                guard let grant = managed.grants.first(where: { $0.libraryID == library.id }), grant.canView else {
                    return nil
                }
                var abilities = ["查看"]
                if grant.canPlay { abilities.append("播放") }
                if grant.canDownload { abilities.append("下载") }
                return (library, abilities.joined(separator: " · "))
            }
        if grants.isEmpty {
            Text("未授权任何媒体库")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 48)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(grants.enumerated()), id: \.element.0.id) { index, entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.0.mediaType.systemImage)
                            .foregroundStyle(AppColors.referenceBlue)
                            .frame(width: 24)
                        Text(entry.0.name).lineLimit(1)
                        Spacer()
                        Text(entry.1).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if index < grants.count - 1 { Divider().padding(.leading, 34) }
                }
            }
        }
    }

    private var securityEvents: some View {
        AppSheetSection(
            title: "最近安全事件",
            systemImage: "checkmark.shield",
            subtitle: "不记录密码、令牌、请求头、IP、文件路径或媒体名称；数据库最多保留 10,000 条。"
        ) {
            let events = Array((store.snapshot?.securityEvents ?? []).prefix(16))
            if events.isEmpty {
                Text("暂无安全事件").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        HStack(spacing: 10) {
                            Image(systemName: event.outcome == .success
                                ? "checkmark.circle.fill" : "exclamationmark.shield.fill")
                                .foregroundStyle(event.outcome == .success ? AppColors.success : AppColors.warning)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(eventTitle(event)).font(.callout.weight(.medium))
                                Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(event.detailCode ?? event.category.rawValue)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        if index < events.count - 1 { Divider().padding(.leading, 34) }
                    }
                }
            }
        }
    }

    private var selectedUser: ServerManagedUserSnapshot? {
        store.snapshot?.users.first { $0.id == selectedUserID }
    }

    private func selectFirstUserIfNeeded() {
        let users = store.snapshot?.users ?? []
        if !users.contains(where: { $0.id == selectedUserID }) {
            selectedUserID = users.first?.id
        }
    }

    private func detailMetric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, shadowed: false)
    }

    private func roleName(_ roleID: String) -> String {
        store.snapshot?.roles.first(where: { $0.id == roleID })?.name ?? "未知角色"
    }

    private func eventTitle(_ event: ServerSecurityEvent) -> String {
        switch event.action {
        case "login.succeeded": "登录成功"
        case "login.rejected": "登录被拒绝"
        case "login.locked": "账号临时锁定"
        case "refresh.succeeded": "会话刷新成功"
        case "refresh.rejected": "会话刷新被拒绝"
        case "logout.succeeded": "用户退出登录"
        case "user.created": "创建服务端用户"
        case "user.access.updated": "更新用户访问权限"
        case "credential.initialized": "初始化管理员凭据"
        case "credential.reset": "重置用户密码"
        case "credential.changed": "修改管理员密码"
        case "credential.change.rejected": "管理员改密被拒绝"
        case "credential.recovered": "本机恢复管理员密码"
        case "credential.recovery.rejected": "管理员恢复被拒绝"
        case "session.revoked": "撤销登录会话"
        case "sessions.revoked.all": "撤销用户全部会话"
        case "device.revoked": "撤销设备"
        default: event.action
        }
    }
}

private struct ServerUserEditorSheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let user: ServerManagedUserSnapshot?
    let libraries: [ServerLibraryOption]
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var displayName: String
    @State private var roleID: String
    @State private var access: [ServerLibraryAccessSelection]
    @State private var disabled: Bool
    @State private var password = ""
    @State private var confirmation = ""

    init(
        store: ServerAdministrationStore,
        user: ServerManagedUserSnapshot?,
        libraries: [ServerLibraryOption],
        onComplete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.store = store
        self.user = user
        self.libraries = libraries
        self.onComplete = onComplete
        self.onCancel = onCancel
        _username = State(initialValue: user?.user.username ?? "")
        _displayName = State(initialValue: user?.user.displayName ?? "")
        _roleID = State(initialValue: user?.roleID ?? ServerIdentityRepository.memberRoleID)
        _disabled = State(initialValue: user?.user.isDisabled ?? false)
        _access = State(initialValue: libraries.map { library in
            let grant = user?.grants.first { $0.libraryID == library.id }
            return ServerLibraryAccessSelection(
                libraryID: library.id,
                canView: grant?.canView ?? false,
                canPlay: grant?.canPlay ?? false,
                canDownload: grant?.canDownload ?? false
            )
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: user == nil ? "新建服务端用户" : "编辑用户权限",
                subtitle: "默认拒绝未授权媒体库；管理员角色不受逐库授权限制。",
                systemImage: user == nil ? "person.badge.plus" : "person.badge.shield.checkmark"
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AppSheetSection(title: "账号", systemImage: "person.crop.circle") {
                        VStack(spacing: 12) {
                            SettingsRow(title: "用户名", systemImage: "at") {
                                TextField("字母、数字、点、横线或下划线", text: $username)
                                    .textFieldStyle(.plain).glassFormField().frame(width: 300)
                                    .disabled(user != nil)
                            }
                            SettingsRow(title: "显示名称", systemImage: "textformat") {
                                TextField("显示名称", text: $displayName)
                                    .textFieldStyle(.plain).glassFormField().frame(width: 300)
                            }
                            SettingsRow(title: "角色", systemImage: "person.badge.key") {
                                Picker("角色", selection: $roleID) {
                                    Text("成员").tag(ServerIdentityRepository.memberRoleID)
                                    Text("管理员").tag(ServerIdentityRepository.administratorRoleID)
                                }
                                .labelsHidden().frame(width: 180)
                            }
                            if user != nil {
                                SettingsRow(title: "账号状态", systemImage: "person.crop.circle.badge.xmark") {
                                    Toggle("停用账号", isOn: $disabled).toggleStyle(.switch)
                                }
                            }
                        }
                    }

                    if user == nil {
                        AppSheetSection(title: "初始密码", systemImage: "key") {
                            VStack(spacing: 12) {
                                SettingsRow(title: "密码", systemImage: "key") {
                                    SecureField("至少 12 个字符", text: $password)
                                        .textFieldStyle(.plain).glassFormField().frame(width: 300)
                                }
                                SettingsRow(title: "确认密码", systemImage: "checkmark.shield") {
                                    SecureField("再次输入", text: $confirmation)
                                        .textFieldStyle(.plain).glassFormField().frame(width: 300)
                                }
                            }
                        }
                    }

                    AppSheetSection(
                        title: "媒体库授权",
                        systemImage: "rectangle.stack.badge.person.crop",
                        subtitle: roleID == ServerIdentityRepository.administratorRoleID
                            ? "管理员可访问全部媒体源；保险库还需要在这台 Mac 上解锁。"
                            : "查看 → 播放 → 下载为递进权限；关闭查看会一并关闭后两项。"
                    ) {
                        VStack(spacing: 0) {
                            ForEach(libraries) { library in
                                libraryAccessRow(library)
                                if library.id != libraries.last?.id { Divider().padding(.leading, 34) }
                            }
                            if libraries.isEmpty {
                                Text("当前没有可授权的媒体源")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                        }
                        .disabled(roleID == ServerIdentityRepository.administratorRoleID)
                    }
                }
            }
            .frame(maxHeight: 520)

            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(AppColors.error)
            }

            AppInfoNote(
                text: "保存权限、停用账号或重置密码都会撤销该用户现有会话，避免旧权限继续生效。",
                systemImage: "lock.shield"
            )
            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(AppSheetSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(store.isWorking)
                Button(user == nil ? "创建用户" : "保存并退出会话") { submit() }
                    .buttonStyle(AppSheetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || store.isWorking)
            }
        }
        .appSheetChrome(width: 680, minHeight: 620, maxHeight: 820)
        .interactiveDismissDisabled(store.isWorking)
        .onDisappear {
            password = ""
            confirmation = ""
            store.clearError()
        }
    }

    private func libraryAccessRow(_ library: ServerLibraryOption) -> some View {
        let index = access.firstIndex(where: { $0.libraryID == library.id })!
        return HStack(spacing: 10) {
            Image(systemName: library.mediaType.systemImage).foregroundStyle(AppColors.referenceBlue).frame(width: 24)
            Text(library.name).lineLimit(1)
            Spacer()
            Toggle("查看", isOn: Binding(
                get: { access[index].canView },
                set: { value in
                    access[index].canView = value
                    if !value { access[index].canPlay = false; access[index].canDownload = false }
                }
            )).toggleStyle(.checkbox)
            Toggle("播放", isOn: Binding(
                get: { access[index].canPlay },
                set: { value in
                    access[index].canPlay = value
                    if value { access[index].canView = true }
                    if !value { access[index].canDownload = false }
                }
            )).toggleStyle(.checkbox)
            Toggle("下载", isOn: Binding(
                get: { access[index].canDownload },
                set: { value in
                    access[index].canDownload = value
                    if value { access[index].canView = true; access[index].canPlay = true }
                }
            )).toggleStyle(.checkbox)
        }
        .padding(.vertical, 8)
    }

    private var canSubmit: Bool {
        let validUsername = !username.isEmpty && username.count <= 64 &&
            username.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        let validDisplayName = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if user != nil { return validUsername && validDisplayName }
        return validUsername && validDisplayName && (12...1_024).contains(password.utf8.count) && password == confirmation
    }

    private func submit() {
        guard canSubmit else { return }
        let submittedPassword = password
        password = ""
        confirmation = ""
        Task { @MainActor in
            let succeeded: Bool
            if let user {
                succeeded = await store.updateUser(
                    id: user.id,
                    displayName: displayName,
                    roleID: roleID,
                    access: access,
                    disabled: disabled
                )
            } else {
                succeeded = await store.createUser(
                    username: username,
                    displayName: displayName,
                    password: submittedPassword,
                    roleID: roleID,
                    access: access
                )
            }
            if succeeded { onComplete() }
        }
    }
}

private struct ServerPasswordResetSheet: View {
    @ObservedObject var store: ServerAdministrationStore
    let user: ServerManagedUserSnapshot
    let onComplete: () -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "重置 \(user.user.displayName) 的密码",
                subtitle: "完成后，该用户的全部 Web 与 Mlink 会话会立即失效。",
                systemImage: "key.horizontal"
            )
            AppSheetSection(title: "新密码", systemImage: "lock.shield") {
                VStack(spacing: 12) {
                    SettingsRow(title: "密码", systemImage: "key") {
                        SecureField("至少 12 个字符", text: $password)
                            .textFieldStyle(.plain).glassFormField().frame(width: 300)
                    }
                    SettingsRow(title: "确认密码", systemImage: "checkmark.shield") {
                        SecureField("再次输入", text: $confirmation)
                            .textFieldStyle(.plain).glassFormField().frame(width: 300)
                    }
                }
            }
            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(AppColors.error)
            }
            AppSheetActionFooter {
                Button("取消", action: onCancel)
                    .buttonStyle(AppSheetSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    .disabled(store.isWorking)
                Button("重置并退出全部会话") { submit() }
                    .buttonStyle(AppSheetPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || store.isWorking)
            }
        }
        .appSheetChrome(width: 590)
        .interactiveDismissDisabled(store.isWorking)
        .onDisappear { password = ""; confirmation = ""; store.clearError() }
    }

    private var canSubmit: Bool {
        (12...1_024).contains(password.utf8.count) && password == confirmation
    }

    private func submit() {
        guard canSubmit else { return }
        let submitted = password
        password = ""
        confirmation = ""
        Task { @MainActor in
            if await store.resetPassword(userID: user.id, password: submitted) { onComplete() }
        }
    }
}
