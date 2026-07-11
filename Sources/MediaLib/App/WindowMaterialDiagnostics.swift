import AppKit
import Foundation

/// 窗口材质诊断仅由启动参数触发，用于确认真实 AppKit 层级，而不是根据截图猜测。
/// 输出不包含媒体名称、路径或用户数据，只记录视图类型、几何信息和材质配置。
@MainActor
enum WindowMaterialDiagnostics {
    private static let modeFlag = "--debug-window-material-report"
    private static let outputFlag = "--debug-window-material-output"
    private static let defaultsFlag = "MediaLib.debug.windowMaterialReport"
    private static var didSchedule = false

    static func scheduleIfRequested() {
        guard (ProcessInfo.processInfo.arguments.contains(modeFlag) ||
               UserDefaults.standard.bool(forKey: defaultsFlag)),
              !didSchedule else { return }
        didSchedule = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            captureWhenReady(attempt: 1)
        }
    }

    private static func captureWhenReady(attempt: Int) {
        guard let window = targetWindow,
              let contentView = window.contentView,
              contentView.bounds.width > 0,
              contentView.bounds.height > 0 else {
            guard attempt < 8 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                captureWhenReady(attempt: attempt + 1)
            }
            return
        }

        let report: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "window": windowDescription(window),
            "viewTree": describe(contentView, in: window)
        ]

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
            print("WINDOW_MATERIAL_REPORT=\(outputURL.path)")
        } catch {
            fputs("WINDOW_MATERIAL_REPORT_FAILED=\(error.localizedDescription)\n", stderr)
        }
    }

    private static var targetWindow: NSWindow? {
        NSApp.windows.first {
            !($0 is NSPanel) && !($0 is ImmersivePlayerWindow) && $0.isVisible
        } ?? NSApp.windows.first {
            !($0 is NSPanel) && !($0 is ImmersivePlayerWindow)
        }
    }

    private static var outputURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: outputFlag),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return URL(fileURLWithPath: "/private/tmp/MediaLib-window-material.json")
    }

    private static func windowDescription(_ window: NSWindow) -> [String: Any] {
        [
            "isOpaque": window.isOpaque,
            "background": nsColorDescription(window.backgroundColor) ?? "none",
            "titlebarAppearsTransparent": window.titlebarAppearsTransparent,
            "styleMask": window.styleMask.rawValue,
            "contentSize": [
                "width": window.contentView?.bounds.width ?? 0,
                "height": window.contentView?.bounds.height ?? 0
            ]
        ]
    }

    private static func describe(_ view: NSView, in window: NSWindow) -> [String: Any] {
        var values: [String: Any] = [
            "class": NSStringFromClass(type(of: view)),
            "frameInWindow": rectDescription(view.convert(view.bounds, to: nil)),
            "isOpaque": view.isOpaque,
            "wantsLayer": view.wantsLayer,
            "layerIsOpaque": view.layer?.isOpaque as Any,
            "layerBackground": cgColorDescription(view.layer?.backgroundColor) ?? "none",
            "subviews": view.subviews.map { describe($0, in: window) }
        ]
        if let effect = view as? NSVisualEffectView {
            values["visualEffect"] = [
                "material": String(describing: effect.material),
                "blendingMode": String(describing: effect.blendingMode),
                "state": String(describing: effect.state),
                "isEmphasized": effect.isEmphasized
            ]
        }
        return values
    }

    private static func rectDescription(_ rect: NSRect) -> [String: CGFloat] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }

    private static func nsColorDescription(_ color: NSColor?) -> String? {
        guard let nsColor = color?.usingColorSpace(.deviceRGB) else { return nil }
        return String(
            format: "%.3f,%.3f,%.3f,%.3f",
            nsColor.redComponent,
            nsColor.greenComponent,
            nsColor.blueComponent,
            nsColor.alphaComponent
        )
    }

    private static func cgColorDescription(_ color: CGColor?) -> String? {
        nsColorDescription(color.flatMap(NSColor.init(cgColor:)))
    }
}
