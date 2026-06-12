import AppKit
import MediaLibCore
import SwiftUI

/// 视频播放器快捷键捕获。
///
/// 旧实现把一个 0×0 的隐藏 `NSView` 塞进 SwiftUI `.background` 并不断抢 `firstResponder`，
/// 但只要用户点了画面、控制条或任意按钮，焦点就转移走，`keyDown` 再也到不了这个隐藏视图，
/// 表现就是“快捷键完全不生效”。这里改为在播放器窗口上安装一个 **窗口级 local 事件监听**，
/// 与第一响应者无关地拦截 keyDown：只在宿主窗口为 key 窗口、且当前不是在文本框里编辑时才处理，
/// 命中映射的动作就消费事件、未命中则原样放行（不吞掉系统/菜单快捷键，也不发出错误提示音）。
struct KeyCaptureView: NSViewRepresentable {
    var settings: AppSettings
    var onKey: (VideoPlayerShortcutAction) -> Void
    /// 「快进」键被按住（系统键重复）/松开时回调，承载长按临时倍速；nil 时保持逐次快进的旧行为。
    var onSeekForwardHold: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: settings, onKey: onKey, onSeekForwardHold: onSeekForwardHold)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.settings = settings
        context.coordinator.onKey = onKey
        context.coordinator.onSeekForwardHold = onSeekForwardHold
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var settings: AppSettings
        var onKey: (VideoPlayerShortcutAction) -> Void
        var onSeekForwardHold: ((Bool) -> Void)?
        private weak var hostView: NSView?
        private var monitor: Any?
        /// 正在长按的「快进」键 keyCode；非 nil 表示临时倍速生效中。
        private var holdingSeekForwardKeyCode: Int?

        init(
            settings: AppSettings,
            onKey: @escaping (VideoPlayerShortcutAction) -> Void,
            onSeekForwardHold: ((Bool) -> Void)?
        ) {
            self.settings = settings
            self.onKey = onKey
            self.onSeekForwardHold = onSeekForwardHold
        }

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func detach() {
            endSeekForwardHoldIfNeeded()
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            hostView = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let hostWindow = hostView?.window else { return event }
            // 只处理当前 key 播放器窗口的按键。部分 keyDown 事件可能没有绑定 window，
            // 这时以宿主窗口是否为 key window 为准，避免快捷键被过严过滤掉。
            guard hostWindow.isKeyWindow else { return event }
            if let eventWindow = event.window, eventWindow !== hostWindow {
                return event
            }
            // 正在文本框/字段编辑器里输入时放行，避免吞掉用户输入。
            if let textView = hostWindow.firstResponder as? NSTextView, textView.isEditable {
                return event
            }

            if event.type == .keyUp {
                if holdingSeekForwardKeyCode == Int(event.keyCode) {
                    endSeekForwardHoldIfNeeded()
                    return nil
                }
                return event
            }

            let shortcut = event.videoKeyboardShortcut
            guard let action = settings.videoPlayerShortcutAction(for: shortcut) else {
                return event
            }
            // 长按「快进」键（系统键重复）→ 临时倍速；松开在 keyUp 里恢复。
            // 第一次按下仍是普通快进；其余动作的键重复保持原样逐次触发。
            if action == .seekForward, let onSeekForwardHold {
                if event.isARepeat {
                    if holdingSeekForwardKeyCode == nil {
                        holdingSeekForwardKeyCode = Int(event.keyCode)
                        onSeekForwardHold(true)
                    }
                    return nil
                }
            }
            onKey(action)
            return nil
        }

        private func endSeekForwardHoldIfNeeded() {
            guard holdingSeekForwardKeyCode != nil else { return }
            holdingSeekForwardKeyCode = nil
            onSeekForwardHold?(false)
        }
    }
}

enum RawCapturedKey: Equatable {
    case space
    case escape
    case leftArrow
    case rightArrow
    case downArrow
    case upArrow
    case character(Character)
}

struct RawKeyCaptureView: NSViewRepresentable {
    var onKey: (RawCapturedKey) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onKey = onKey
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onKey = onKey
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var onKey: ((RawCapturedKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let key = event.rawKeyEquivalent else {
                super.keyDown(with: event)
                return
            }
            onKey?(key)
        }
    }
}

struct VideoShortcutRecorderView: NSViewRepresentable {
    var onCapture: (VideoKeyboardShortcut) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((VideoKeyboardShortcut) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            onCapture?(event.videoKeyboardShortcut)
        }
    }
}

private extension NSEvent {
    var rawKeyEquivalent: RawCapturedKey? {
        switch keyCode {
        case 49: return .space
        case 53: return .escape
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:
            guard let character = charactersIgnoringModifiers?.first else { return nil }
            return .character(character)
        }
    }

    var videoKeyboardShortcut: VideoKeyboardShortcut {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: VideoShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        return VideoKeyboardShortcut(
            keyCode: Int(keyCode),
            characters: charactersIgnoringModifiers?.lowercased() ?? "",
            modifiers: modifiers
        )
    }
}
