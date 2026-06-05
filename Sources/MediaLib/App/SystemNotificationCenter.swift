import AppKit
import Foundation
import UserNotifications

/// 系统通知（Phase 4）：后台任务完成后向通知中心发本地通知。
/// 仅在 App 拥有有效 bundle identifier 时启用（避免未打包运行时崩溃）。
@MainActor
enum SystemNotificationCenter {
    /// 未打包（无 bundle id）时 UNUserNotificationCenter.current() 会崩溃，这里统一守卫。
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 请求授权（用户在设置中打开开关时调用）。回调返回是否获授权。
    static func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        guard isAvailable else { completion?(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion?(granted) }
        }
    }

    /// 发送一条通知（已授权才会真正展示）。
    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
