import AppKit
import UniformTypeIdentifiers

/// 把 MediaLIB 注册为常见视频/音乐格式的系统默认打开方式。
/// 前提是 app 以 .app 包形式运行且 Info.plist 声明了对应文档类型
/// （由 scripts/package_dmg.sh 写入）；swift run 的裸二进制无法注册。
@MainActor
enum SystemDefaultPlayerRegistrar {
    static let videoExtensions = [
        "mp4", "mkv", "avi", "mov", "m4v", "wmv", "flv",
        "ts", "m2ts", "webm", "mpg", "mpeg", "rmvb", "rm", "3gp", "vob"
    ]
    static let musicExtensions = [
        "mp3", "flac", "m4a", "aac", "wav", "ogg", "opus", "ape", "aiff", "wma"
    ]

    static var runningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// 逐个扩展名向 LaunchServices 注册默认打开方式，返回成功/失败数。
    static func register(extensions: [String]) async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext) else {
                failed += 1
                continue
            }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                succeeded += 1
            } catch {
                failed += 1
            }
        }
        return (succeeded, failed)
    }
}
