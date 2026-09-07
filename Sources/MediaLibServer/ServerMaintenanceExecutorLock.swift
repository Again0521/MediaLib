import Darwin
import Foundation

enum ServerMaintenanceExecutorLockError: Error, LocalizedError, Equatable {
    case unsafeLockFile
    case openFailed
    case alreadyHeld
    case lockFailed

    var errorDescription: String? {
        switch self {
        case .unsafeLockFile:
            return "维护执行者锁文件不安全，服务已拒绝启动。"
        case .openFailed:
            return "无法创建维护执行者锁，服务已拒绝启动。"
        case .alreadyHeld:
            return "同一数据目录已有维护执行者，服务已拒绝重复启动。"
        case .lockFailed:
            return "无法取得维护执行者锁，服务已拒绝启动。"
        }
    }
}

/// A kernel-owned advisory lock for the server maintenance executor. The descriptor stays open
/// for the process lifetime and the kernel releases it automatically on process exit.
final class ServerMaintenanceExecutorLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func acquire(
        in dataDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ServerMaintenanceExecutorLock {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dataDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ServerMaintenanceExecutorLockError.openFailed
        }
        let lockURL = dataDirectory.appendingPathComponent(".medialib-maintenance.lock", isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ServerMaintenanceExecutorLockError.unsafeLockFile }
            throw ServerMaintenanceExecutorLockError.openFailed
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid() else {
            _ = close(descriptor)
            throw ServerMaintenanceExecutorLockError.unsafeLockFile
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            _ = close(descriptor)
            throw ServerMaintenanceExecutorLockError.openFailed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw ServerMaintenanceExecutorLockError.alreadyHeld
            }
            throw ServerMaintenanceExecutorLockError.lockFailed
        }
        return ServerMaintenanceExecutorLock(descriptor: descriptor)
    }
}
