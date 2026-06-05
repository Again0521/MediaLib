import AVFoundation
import AVKit
import AppKit
import SwiftUI

@MainActor
final class AirPlayRoutePickerSession: ObservableObject {
    private let delegate = Delegate()
    private var lastPlayer: AVPlayer?

    init() {}

    func makeRoutePickerView() -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView(frame: .zero)
        routePickerView.delegate = delegate
        routePickerView.isRoutePickerButtonBordered = false
        routePickerView.translatesAutoresizingMaskIntoConstraints = false
        return routePickerView
    }

    func configure(
        routePickerView: AVRoutePickerView,
        player: AVPlayer?,
        tintColor: NSColor,
        activeTintColor: NSColor,
        prioritizesVideoDevices: Bool,
        onRoutesWillBegin: (() -> Void)?,
        onRoutesDidEnd: (() -> Void)?
    ) {
        delegate.onRoutesWillBegin = onRoutesWillBegin
        delegate.onRoutesDidEnd = onRoutesDidEnd
        #if !os(macOS)
        routePickerView.prioritizesVideoDevices = prioritizesVideoDevices
        #endif

        if let player {
            if routePickerView.player !== player {
                routePickerView.player = player
            }
            lastPlayer = player
        } else if let lastPlayer, routePickerView.player !== lastPlayer {
            routePickerView.player = lastPlayer
        }

        routePickerView.setRoutePickerButtonColor(tintColor, for: .normal)
        routePickerView.setRoutePickerButtonColor(tintColor.withAlphaComponent(0.86), for: .normalHighlighted)
        routePickerView.setRoutePickerButtonColor(activeTintColor, for: .active)
        routePickerView.setRoutePickerButtonColor(activeTintColor.withAlphaComponent(0.88), for: .activeHighlighted)
    }

    func presentRoutesWhenReady(from routePickerView: AVRoutePickerView, retryCount: Int = 0) {
        if presentRoutes(from: routePickerView) {
            return
        }
        guard retryCount < 5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak routePickerView, weak self] in
            guard let routePickerView, let self else { return }
            self.presentRoutesWhenReady(from: routePickerView, retryCount: retryCount + 1)
        }
    }

    @discardableResult
    private func presentRoutes(from routePickerView: AVRoutePickerView) -> Bool {
        routePickerView.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        routePickerView.layoutSubtreeIfNeeded()
        if let button = Self.findRouteButton(in: routePickerView) {
            button.performClick(nil)
            return true
        }

        guard let window = routePickerView.window else { return false }
        let centerInWindow = routePickerView.convert(
            CGPoint(x: routePickerView.bounds.midX, y: routePickerView.bounds.midY),
            to: nil
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        let windowNumber = window.windowNumber
        let events: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp]
        for eventType in events {
            guard let event = NSEvent.mouseEvent(
                with: eventType,
                location: centerInWindow,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: eventType == .leftMouseDown ? 1 : 0
            ) else { continue }
            if eventType == .leftMouseDown {
                routePickerView.mouseDown(with: event)
            } else {
                routePickerView.mouseUp(with: event)
            }
        }
        return true
    }

    private static func findRouteButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton {
            return button
        }
        for subview in view.subviews {
            if let button = findRouteButton(in: subview) {
                return button
            }
        }
        return nil
    }

    private final class Delegate: NSObject, AVRoutePickerViewDelegate {
        var onRoutesWillBegin: (() -> Void)?
        var onRoutesDidEnd: (() -> Void)?

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onRoutesWillBegin?()
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onRoutesDidEnd?()
        }
    }
}

struct AirPlayRoutePickerButton: NSViewRepresentable {
    var session: AirPlayRoutePickerSession
    var player: AVPlayer?
    var tintColor: NSColor
    var activeTintColor: NSColor
    var prioritizesVideoDevices = false
    var onRoutesWillBegin: (() -> Void)?
    var onRoutesDidEnd: (() -> Void)?
    var activationID: Int

    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePickerView = session.makeRoutePickerView()
        configure(routePickerView)
        context.coordinator.activationID = activationID
        return routePickerView
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        configure(nsView)
        guard context.coordinator.activationID != activationID else { return }
        context.coordinator.activationID = activationID
        onRoutesWillBegin?()
        DispatchQueue.main.async {
            session.presentRoutesWhenReady(from: nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(activationID: activationID)
    }

    private func configure(_ routePickerView: AVRoutePickerView) {
        session.configure(
            routePickerView: routePickerView,
            player: player,
            tintColor: tintColor,
            activeTintColor: activeTintColor,
            prioritizesVideoDevices: prioritizesVideoDevices,
            onRoutesWillBegin: onRoutesWillBegin,
            onRoutesDidEnd: onRoutesDidEnd
        )
    }

    final class Coordinator {
        var activationID: Int

        init(activationID: Int) {
            self.activationID = activationID
        }
    }
}

struct AirPlayRoutePickerControl: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var localSession = AirPlayRoutePickerSession()
    @State private var activationID = 0
    var session: AirPlayRoutePickerSession?
    var player: AVPlayer?
    var tintColor: NSColor = .labelColor
    var activeTintColor: NSColor = .controlAccentColor
    var lightTint: Color = AppColors.pointerLightTint
    var systemImage = "airplayaudio"
    var prioritizesVideoDevices = false
    var size: CGFloat = 30
    var cornerRadius: CGFloat = 15
    var useGlassBackground = true
    var glowStrength: Double = 1
    var onRoutesWillBegin: (() -> Void)?
    var onRoutesDidEnd: (() -> Void)?

    var body: some View {
        let activeSession = session ?? localSession

        ZStack {
            if useGlassBackground {
                Circle()
                    .fill(.regularMaterial)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.15 : 0.58),
                                lightTint.opacity(colorScheme == .dark ? 0.20 : 0.24),
                                lightTint.opacity(colorScheme == .dark ? 0.08 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            AirPlayRoutePickerButton(
                session: activeSession,
                player: player,
                tintColor: tintColor,
                activeTintColor: activeTintColor,
                prioritizesVideoDevices: prioritizesVideoDevices,
                onRoutesWillBegin: onRoutesWillBegin,
                onRoutesDidEnd: onRoutesDidEnd,
                activationID: activationID
            )
            .frame(width: size, height: size)
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Button {
                activationID &+= 1
            } label: {
                Image(systemName: systemImage)
                    .font(.system(size: max(13, size * 0.45), weight: .semibold))
                    .foregroundStyle(Color(nsColor: activeTintColor))
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .overlay {
            if useGlassBackground {
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.30 : 0.78),
                                lightTint.opacity(colorScheme == .dark ? 0.30 : 0.38),
                                .white.opacity(colorScheme == .dark ? 0.10 : 0.34)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        }
        .shadow(color: lightTint.opacity((colorScheme == .dark ? 0.14 : 0.11) * glowStrength), radius: 10 + 5 * glowStrength, y: 5)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.052), radius: 10, y: 5)
        .pointerLiquidEdge(cornerRadius: cornerRadius, tint: lightTint, intensity: 1.06 * glowStrength)
        .help("隔空播放")
        .accessibilityLabel("隔空播放")
    }
}
