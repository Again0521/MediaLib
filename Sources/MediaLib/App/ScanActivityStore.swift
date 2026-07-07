import Combine
import Foundation
import MediaLibCore

/// 扫描运行态的状态容器。
///
/// 只承载扫描进度、是否扫描中和队列计数；扫描调度、文件系统 I/O、reload 编排仍归 AppState
/// 的扫描流程负责，避免这个 Store 演化成新的扫描 god object。
@MainActor
final class ScanActivityStore: ObservableObject {
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var queueCount = 0

    func setProgress(_ progress: ScanProgress?) {
        self.progress = progress
    }

    func setScanning(_ isScanning: Bool) {
        self.isScanning = isScanning
    }

    func setQueueCount(_ queueCount: Int) {
        self.queueCount = max(queueCount, 0)
    }

    func begin(queueCount: Int) {
        isScanning = true
        self.queueCount = max(queueCount, 0)
    }

    func finish() {
        progress = nil
        isScanning = false
        queueCount = 0
    }
}
