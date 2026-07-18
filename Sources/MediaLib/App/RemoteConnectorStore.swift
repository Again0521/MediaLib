import Combine
import Foundation
import MediaLibCore

/// 远程连接器的轻量状态容器。
///
/// 只拥有账户列表和媒体服务器连接中的 UI 状态；登录、凭据存储、远程库同步、Trakt 冲突处理
/// 和失败回滚仍由 AppState 过渡层编排，避免这个 Store 变成远程同步 god object。
@MainActor
final class RemoteConnectorStore: ObservableObject {
    @Published private(set) var accounts: [RemoteConnectorAccount] = []
    @Published private(set) var isConnectingEmby = false
    @Published private(set) var isConnectingJellyfin = false
    @Published private(set) var isConnectingPlex = false
    @Published private(set) var isConnectingMlink = false

    func replaceAccounts(_ accounts: [RemoteConnectorAccount]) {
        self.accounts = accounts
    }

    func upsert(_ account: RemoteConnectorAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    func removeAccounts(where shouldRemove: (RemoteConnectorAccount) -> Bool) {
        accounts.removeAll(where: shouldRemove)
    }

    func isConnecting(_ provider: RemoteConnectorProvider) -> Bool {
        switch provider {
        case .emby:
            return isConnectingEmby
        case .jellyfin:
            return isConnectingJellyfin
        case .plex:
            return isConnectingPlex
        case .mlink:
            return isConnectingMlink
        default:
            return false
        }
    }

    func setConnecting(_ provider: RemoteConnectorProvider, _ connecting: Bool) {
        switch provider {
        case .emby:
            isConnectingEmby = connecting
        case .jellyfin:
            isConnectingJellyfin = connecting
        case .plex:
            isConnectingPlex = connecting
        case .mlink:
            isConnectingMlink = connecting
        default:
            break
        }
    }
}
