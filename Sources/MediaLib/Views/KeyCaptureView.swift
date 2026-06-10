import AppKit
import MediaLibCore
import SwiftUI

struct KeyCaptureView: NSViewRepresentable {
    var settings: AppSettings
    var onKey: (VideoPlayerShortcutAction) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.settings = settings
        view.onKey = onKey
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.settings = settings
        nsView.onKey = onKey
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var settings = AppSettings()
        var onKey: ((VideoPlayerShortcutAction) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let shortcut = event.videoKeyboardShortcut
            if let action = settings.videoPlayerShortcutAction(for: shortcut) {
                onKey?(action)
                return
            }
            super.keyDown(with: event)
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
