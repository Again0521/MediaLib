import Combine
import Foundation

/// 保险库隐私锁的展示/可见性状态容器。
///
/// 只保存“是否已设置 PIN”和“当前是否解锁”；PIN 文件读写、Touch ID、设置持久化、
/// 详情清理和私密播放停止仍由 AppState 与隐私锁服务编排。
@MainActor
final class PrivacyLockStateStore: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var isPINConfigured = false

    func setUnlocked(_ unlocked: Bool) {
        isUnlocked = unlocked
    }

    func setPINConfigured(_ configured: Bool) {
        isPINConfigured = configured
    }

    func configurePINAndUnlock() {
        isPINConfigured = true
        isUnlocked = true
    }

    func lock() {
        isUnlocked = false
    }

    func clearPINConfiguration() {
        isPINConfigured = false
        isUnlocked = false
    }
}
