import AppKit
import Foundation
import MediaLibCore

@MainActor
enum LiveTitleIconDebugTool {
    private static let modeFlag = "--debug-live-title-icons"
    private static let destinationFlag = "--debug-live-title-icons-destination"
    private static let outputFlag = "--debug-live-title-icons-output"
    private static let delayFlag = "--debug-live-title-icons-delay"
    private static let sidebarSelectionKey = "MediaLib.sidebar.selection"

    private static var didPrepare = false
    private static var didSchedule = false
    private static var previousSelection: String?

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(modeFlag)
    }

    static func prepareInitialSelectionIfRequested() {
        guard isRequested, !didPrepare else { return }
        didPrepare = true
        previousSelection = UserDefaults.standard.string(forKey: sidebarSelectionKey)
        UserDefaults.standard.set(destinationID, forKey: sidebarSelectionKey)
    }

    static func adjustSettingsForDebug(_ settings: inout AppSettings) {
        guard isRequested else { return }
        settings.hasCompletedOnboarding = true
    }

    static func scheduleWindowCaptureIfRequested() {
        guard isRequested, !didSchedule else { return }
        didSchedule = true
        print("LIVE_TITLE_ICON_DEBUG scheduled destination=\(destinationID) delay=\(delaySeconds)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
            captureWhenWindowIsReady(attempt: 1)
        }
    }

    private static var destinationID: String {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: destinationFlag),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            return arguments[index + 1]
        }
        return "video-tvShows"
    }

    private static var outputDirectory: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: outputFlag),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Build/TitleIconLiveDebug", isDirectory: true)
    }

    private static var delaySeconds: TimeInterval {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: delayFlag),
              arguments.indices.contains(index + 1),
              let value = TimeInterval(arguments[index + 1]) else { return 2.1 }
        return max(0.3, min(value, 8.0))
    }

    private static var fileStem: String {
        destinationID
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "__", with: "-")
    }

    private static func captureWhenWindowIsReady(attempt: Int) {
        guard let window = targetWindow,
              window.contentView?.bounds.width ?? 0 > 0,
              window.contentView?.bounds.height ?? 0 > 0 else {
            if attempt < 12 {
                print("LIVE_TITLE_ICON_DEBUG waiting_for_window destination=\(destinationID) attempt=\(attempt)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    captureWhenWindowIsReady(attempt: attempt + 1)
                }
            } else {
                captureWindowAndExit()
            }
            return
        }
        prepareWindowForCapture(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            captureWindowAndExit()
        }
    }

    private static func prepareWindowForCapture(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 1360, height: 900))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static var targetWindow: NSWindow? {
        NSApp.windows.first {
            !($0 is NSPanel) &&
            !($0 is ImmersivePlayerWindow) &&
            $0.isVisible
        } ?? NSApp.windows.first {
            !($0 is NSPanel) &&
            !($0 is ImmersivePlayerWindow)
        }
    }

    private static func captureWindowAndExit() {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            guard let window = targetWindow,
                  let contentView = window.contentView else {
                throw debugError("没有找到可截图的主窗口。")
            }
            contentView.layoutSubtreeIfNeeded()
            let bounds = contentView.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw debugError("主窗口内容尺寸无效，无法截图。")
            }
            contentView.cacheDisplay(in: bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw debugError("无法编码实机截图 PNG。")
            }

            let imageURL = outputDirectory.appendingPathComponent("\(fileStem).png")
            let reportURL = outputDirectory.appendingPathComponent("\(fileStem).json")
            try data.write(to: imageURL, options: .atomic)
            try writeReport(to: reportURL, imageName: imageURL.lastPathComponent, window: window, bounds: bounds)
            restoreSelection()
            print("LIVE_TITLE_ICON_CAPTURE=\(imageURL.path)")
            print("LIVE_TITLE_ICON_REPORT=\(reportURL.path)")
            NSApp.terminate(nil)
        } catch {
            restoreSelection()
            fputs("FAILED: live title icon capture failed for \(destinationID): \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private static func writeReport(to url: URL, imageName: String, window: NSWindow, bounds: NSRect) throws {
        let report: [String: Any] = [
            "destinationID": destinationID,
            "image": imageName,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "windowFrame": [
                "x": window.frame.origin.x,
                "y": window.frame.origin.y,
                "width": window.frame.width,
                "height": window.frame.height
            ],
            "contentBounds": [
                "width": bounds.width,
                "height": bounds.height
            ],
            "usesRealAppWindow": true,
            "usesSidebarSelectionKey": sidebarSelectionKey
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func restoreSelection() {
        if let previousSelection {
            UserDefaults.standard.set(previousSelection, forKey: sidebarSelectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sidebarSelectionKey)
        }
    }

    private static func debugError(_ message: String) -> NSError {
        NSError(domain: "LiveTitleIconDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
