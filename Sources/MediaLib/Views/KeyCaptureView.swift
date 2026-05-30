import AppKit
import SwiftUI

enum CapturedKey: Equatable {
    case space
    case escape
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case seekBackwardSmall
    case seekForwardSmall
    case seekBackwardLarge
    case seekForwardLarge
    case beginning
    case ending
    case returnKey
    case pageUp
    case pageDown
    case fullscreen
    case closeWindow
    case mute
    case k
    case j
    case l
    case speedDown
    case speedUp
    case resetSpeed
    case frameBackward
    case frameForward
    case subtitleCycle
    case subtitleToggle
    case audioCycle
    case number(Int)
    case other
}

struct KeyCaptureView: NSViewRepresentable {
    var onKey: (CapturedKey) -> Void

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
        var onKey: ((CapturedKey) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let command = flags.contains(.command)
            let option = flags.contains(.option)
            let shift = flags.contains(.shift)

            if command {
                switch characters {
                case "f":
                    onKey?(.fullscreen)
                    return
                case "w":
                    onKey?(.closeWindow)
                    return
                default:
                    break
                }
            }

            switch event.keyCode {
            case 49:
                onKey?(.space)
            case 53:
                onKey?(.escape)
            case 123:
                if command {
                    onKey?(.beginning)
                } else if option {
                    onKey?(.seekBackwardLarge)
                } else if shift {
                    onKey?(.seekBackwardSmall)
                } else {
                    onKey?(.leftArrow)
                }
            case 124:
                if command {
                    onKey?(.ending)
                } else if option {
                    onKey?(.seekForwardLarge)
                } else if shift {
                    onKey?(.seekForwardSmall)
                } else {
                    onKey?(.rightArrow)
                }
            case 125:
                onKey?(.downArrow)
            case 126:
                onKey?(.upArrow)
            case 36, 76:
                onKey?(.returnKey)
            case 115:
                onKey?(.beginning)
            case 119:
                onKey?(.ending)
            case 116:
                onKey?(.pageUp)
            case 121:
                onKey?(.pageDown)
            default:
                if command {
                    super.keyDown(with: event)
                    return
                }
                if let number = Int(characters), (0...9).contains(number) {
                    onKey?(.number(number))
                } else {
                    switch characters {
                    case "f":
                        onKey?(.fullscreen)
                    case "m":
                        onKey?(.mute)
                    case "k":
                        onKey?(.k)
                    case "j":
                        onKey?(.j)
                    case "l":
                        onKey?(.l)
                    case "[":
                        onKey?(.speedDown)
                    case "]":
                        onKey?(.speedUp)
                    case "\\":
                        onKey?(.resetSpeed)
                    case ",":
                        onKey?(.frameBackward)
                    case ".":
                        onKey?(.frameForward)
                    case "c":
                        onKey?(.subtitleCycle)
                    case "v":
                        onKey?(.subtitleToggle)
                    case "a":
                        onKey?(.audioCycle)
                    case "q":
                        onKey?(.closeWindow)
                    default:
                        onKey?(.other)
                        super.keyDown(with: event)
                    }
                }
            }
        }
    }
}
