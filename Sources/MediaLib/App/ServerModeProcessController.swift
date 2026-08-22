import Combine
import Foundation
import MediaLibCore

@MainActor
final class ServerModeProcessController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var title: String {
            switch self {
            case .stopped: return "已停止"
            case .starting: return "正在启动"
            case .running: return "本机服务运行中"
            case .failed: return "启动失败"
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    private var process: Process?
    private var readinessTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// `nil` only when the user (or application termination) explicitly stops
    /// server mode. An unexpected child exit must not silently turn a running
    /// Web server into an unreachable browser tab.
    private var requestedConfiguration: ServerModeConfiguration?
    private let executableURLProvider: @MainActor () throws -> URL
    private let readinessChecker: (ServerModeConfiguration) async -> Bool
    private let readinessTimeout: TimeInterval

    init() {
        executableURLProvider = Self.defaultServerExecutableURL
        readinessChecker = ServerModeProcessController.defaultReadinessChecker
        readinessTimeout = 5
    }

    init(
        executableURLProvider: @escaping @MainActor () throws -> URL,
        readinessChecker: @escaping (ServerModeConfiguration) async -> Bool = ServerModeProcessController.defaultReadinessChecker,
        readinessTimeout: TimeInterval = 5
    ) {
        self.executableURLProvider = executableURLProvider
        self.readinessChecker = readinessChecker
        self.readinessTimeout = max(readinessTimeout, 0.05)
    }

    deinit {
        readinessTask?.cancel()
        restartTask?.cancel()
        process?.terminate()
    }

    func start(configuration: ServerModeConfiguration) throws {
        guard process == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        requestedConfiguration = configuration
        status = .starting

        do {
            let executableURL = try executableURLProvider()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["--serve"]
            process.environment = Self.processEnvironment(
                configuration: configuration,
                base: ProcessInfo.processInfo.environment
            )
            process.qualityOfService = configuration.isLightweightMode ? .utility : .userInitiated
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self, weak process] terminatedProcess in
                let code = terminatedProcess.terminationStatus
                Task { @MainActor in
                    guard let self, self.process === process else { return }
                    self.readinessTask?.cancel()
                    self.readinessTask = nil
                    self.process = nil
                    if terminatedProcess.terminationReason == .exit && code == 0 {
                        self.status = .stopped
                    } else {
                        self.status = .failed("服务进程意外退出（代码 \(code)）。")
                        self.scheduleUnexpectedExitRecovery(after: 1)
                    }
                }
            }

            try process.run()
            self.process = process
            // Process.run() only proves that the child was forked. The Web button and
            // status must not claim availability until the actual HTTP health endpoint
            // responds; this closes the port-race/slow-database startup window.
            readinessTask?.cancel()
            readinessTask = Task { [weak self, weak process] in
                guard let self, let process else { return }
                let deadline = Date().addingTimeInterval(self.readinessTimeout)
                while !Task.isCancelled, Date() < deadline {
                    guard process.isRunning else { return }
                    if await self.readinessChecker(configuration) {
                        guard process.isRunning, self.process === process else { return }
                        self.status = .running
                        self.readinessTask = nil
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                guard !Task.isCancelled, self.process === process else { return }
                self.process = nil
                if process.isRunning { process.terminate() }
                self.status = .failed("服务进程未在 \(Int(self.readinessTimeout.rounded(.up))) 秒内通过 Web 健康检查。")
                self.readinessTask = nil
            }
        } catch {
            requestedConfiguration = nil
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        restartTask?.cancel()
        restartTask = nil
        requestedConfiguration = nil
        guard let process else {
            status = .stopped
            return
        }
        self.process = nil
        if process.isRunning {
            process.terminate()
        }
        status = .stopped
    }

    /// 恢复管理员凭据前使用：停止 App 管理的服务进程，并等待真实进程退出，
    /// 避免仅更新 UI 状态后仍有旧进程短暂持有数据库或认证状态。
    func stopAndWaitForExit(timeout: TimeInterval = 5) async -> Bool {
        restartTask?.cancel()
        restartTask = nil
        requestedConfiguration = nil
        guard let process else {
            readinessTask?.cancel()
            readinessTask = nil
            status = .stopped
            return true
        }
        readinessTask?.cancel()
        readinessTask = nil
        // 先解除 terminationHandler 与当前控制器的身份关联，主动终止不应被报告为崩溃。
        self.process = nil
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(max(timeout, 0.1))
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !process.isRunning else {
            status = .failed("服务进程未能在安全恢复前停止。")
            return false
        }
        status = .stopped
        return true
    }

    private func scheduleUnexpectedExitRecovery(after delay: TimeInterval) {
        guard restartTask == nil, let configuration = requestedConfiguration else { return }
        restartTask = Task { [weak self] in
            let nanoseconds = UInt64(max(delay, 0.1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.process == nil,
                  self.requestedConfiguration == configuration
            else { return }
            self.restartTask = nil
            do {
                try self.start(configuration: configuration)
            } catch {
                // `start` already presents a localized, non-sensitive error.
                // Keep the explicit requested configuration so the user can
                // retry by toggling Server Mode instead of reviving a child
                // after an application-initiated stop.
            }
        }
    }

    private static func defaultReadinessChecker(_ configuration: ServerModeConfiguration) async -> Bool {
        if configuration.networkAccessMode == .lanHTTPS {
            return await checkLANHTTPSReadiness(configuration)
        }
        var request = URLRequest(url: configuration.loopbackBaseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 0.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else { return false }
        return httpResponse.statusCode == 200
    }

    private static func checkLANHTTPSReadiness(_ configuration: ServerModeConfiguration) async -> Bool {
        guard configuration.lanHTTPSBaseURL != nil,
              let directories = try? FileAccessService.appDirectories()
        else { return false }
        let certificateURL = ServerModeCertificateSupport.certificateAuthorityURL(
            applicationSupport: directories.applicationSupport
        )
        return await checkLANHTTPSReadiness(
            configuration,
            certificateAuthorityURL: certificateURL
        )
    }

    static func checkLANHTTPSReadiness(
        _ configuration: ServerModeConfiguration,
        certificateAuthorityURL: URL
    ) async -> Bool {
        guard let baseURL = configuration.lanHTTPSBaseURL,
              let host = baseURL.host
        else { return false }
        guard let delegate = try? ServerModePinnedTrustDelegate(
            expectedHost: host,
            certificateAuthorityURL: certificateAuthorityURL
        ) else { return false }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 0.75
        sessionConfiguration.timeoutIntervalForResource = 1
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 0.75
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else { return false }
        return httpResponse.statusCode == 200
    }

    private static func defaultServerExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MediaLibServer"),
            CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("MediaLibServer") }
        ].compactMap { $0 }

        if let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return executable
        }
        throw ServerModeProcessError.runtimeNotFound
    }

    static func processEnvironment(
        configuration: ServerModeConfiguration,
        base: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        environment["MEDIALIB_SERVER_HOST"] = "127.0.0.1"
        environment["MEDIALIB_SERVER_PORT"] = String(configuration.port)
        environment["MEDIALIB_SERVER_ID"] = configuration.serverID
        environment["MEDIALIB_SERVER_NAME"] = configuration.serverName
        environment["MEDIALIB_SERVER_NETWORK_ACCESS_MODE"] = configuration.networkAccessMode.rawValue
        environment["MEDIALIB_SERVER_LIGHTWEIGHT"] = configuration.isLightweightMode ? "1" : "0"
        if let publicOrigin = configuration.effectivePublicOrigin {
            environment["MEDIALIB_SERVER_PUBLIC_ORIGIN"] = publicOrigin
        } else {
            environment.removeValue(forKey: "MEDIALIB_SERVER_PUBLIC_ORIGIN")
        }
        if configuration.effectiveTrustedProxyAddresses.isEmpty {
            environment.removeValue(forKey: "MEDIALIB_SERVER_TRUSTED_PROXIES")
        } else {
            environment["MEDIALIB_SERVER_TRUSTED_PROXIES"] = configuration.effectiveTrustedProxyAddresses.joined(separator: ",")
        }
        return environment
    }
}

private enum ServerModeProcessError: LocalizedError {
    case runtimeNotFound

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "未找到随 MediaLIB 安装的 MediaLibServer 服务端运行程序。请重新安装完整应用后重试。"
        }
    }
}
