import Combine
import Foundation

/// Trakt 连接/导入流程的进行中状态容器。
///
/// 只保存设置页按钮禁用态和并发闸门；设备码轮询、token 刷新、远端状态拉取、
/// 同步冲突生成、Trakt 写回和提示副作用仍由 AppState+TraktSync 编排。
@MainActor
final class TraktSyncActivityStore: ObservableObject {
    @Published private(set) var isConnecting = false
    @Published private(set) var isImporting = false

    func setConnecting(_ connecting: Bool) {
        isConnecting = connecting
    }

    func setImporting(_ importing: Bool) {
        isImporting = importing
    }

    func beginConnecting() {
        isConnecting = true
    }

    func finishConnecting() {
        isConnecting = false
    }

    func beginImporting() {
        isImporting = true
    }

    func finishImporting() {
        isImporting = false
    }
}
