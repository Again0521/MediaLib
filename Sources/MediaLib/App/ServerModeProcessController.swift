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
    private let executableURLProvider: @MainActor () throws -> URL

    init() {
        executableURLProvider = Self.defaultServerExecutableURL
    }

    init(executableURLProvider: @escaping @MainActor () throws -> URL) {
        self.executableURLProvider = executableURLProvider
    }

    deinit {
        process?.terminate()
    }

    func start(configuration: ServerModeConfiguration) throws {
        guard process == nil else { return }
        status = .starting

        do {
            let executableURL = try executableURLProvider()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["--serve"]
            var environment = ProcessInfo.processInfo.environment
            environment["MEDIALIB_SERVER_HOST"] = "127.0.0.1"
            environment["MEDIALIB_SERVER_PORT"] = String(configuration.port)
            environment["MEDIALIB_SERVER_ID"] = configuration.serverID
            environment["MEDIALIB_SERVER_NAME"] = configuration.serverName
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self, weak process] terminatedProcess in
                let code = terminatedProcess.terminationStatus
                Task { @MainActor in
                    guard let self, self.process === process else { return }
                    self.process = nil
                    if terminatedProcess.terminationReason == .exit && code == 0 {
                        self.status = .stopped
                    } else {
                        self.status = .failed("服务进程意外退出（代码 \(code)）。")
                    }
                }
            }

            try process.run()
            self.process = process
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
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
        guard let process else {
            status = .stopped
            return true
        }
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
