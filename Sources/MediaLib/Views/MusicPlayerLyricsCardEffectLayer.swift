import AppKit
import SwiftUI

struct LyricsCardEffectLayerView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let intensity: Double
    let colorScheme: ColorScheme
    let isEnabled: Bool

    func makeNSView(context: Context) -> EffectView {
        let view = EffectView(frame: .zero)
        view.update(
            cornerRadius: cornerRadius,
            intensity: intensity,
            colorScheme: colorScheme,
            isEnabled: isEnabled
        )
        return view
    }

    func updateNSView(_ nsView: EffectView, context: Context) {
        nsView.update(
            cornerRadius: cornerRadius,
            intensity: intensity,
            colorScheme: colorScheme,
            isEnabled: isEnabled
        )
    }

    final class EffectView: NSView {
        private let effectLayer = PointerWashLayer()
        private var trackingArea: NSTrackingArea?
        private var lastPointerLocation: CGPoint?
        private var lastPointerUpdate = Date.distantPast
        private let updateInterval: TimeInterval = 1.0 / 30.0
        private let minDistance: CGFloat = 5.5

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectLayer.frame = bounds
            effectLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            effectLayer.setNeedsDisplay()
            CATransaction.commit()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let options: NSTrackingArea.Options = [
                .mouseMoved,
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect
            ]
            let next = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            trackingArea = next
            addTrackingArea(next)
        }

        override func mouseEntered(with event: NSEvent) {
            updatePointer(with: event, force: true)
        }

        override func mouseMoved(with event: NSEvent) {
            updatePointer(with: event, force: false)
        }

        override func mouseExited(with event: NSEvent) {
            lastPointerLocation = nil
            effectLayer.pointer = nil
            effectLayer.setNeedsDisplay()
        }

        func update(
            cornerRadius: CGFloat,
            intensity: Double,
            colorScheme: ColorScheme,
            isEnabled: Bool
        ) {
            effectLayer.cornerRadiusValue = cornerRadius
            effectLayer.intensity = min(max(intensity, 0), 1.45)
            effectLayer.isDark = colorScheme == .dark
            effectLayer.isEffectEnabled = isEnabled
            if !isEnabled {
                lastPointerLocation = nil
                effectLayer.pointer = nil
            }
            effectLayer.setNeedsDisplay()
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = false
            effectLayer.masksToBounds = false
            effectLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            effectLayer.compositingFilter = "screenBlendMode"
            layer?.addSublayer(effectLayer)
        }

        private func updatePointer(with event: NSEvent, force: Bool) {
            guard effectLayer.isEffectEnabled, bounds.width > 0, bounds.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else {
                mouseExited(with: event)
                return
            }
            let now = Date()
            if !force,
               !PointerHoverThrottle.shouldUpdate(
                    from: lastPointerLocation,
                    previousUpdate: lastPointerUpdate,
                    to: point,
                    now: now,
                    minInterval: updateInterval,
                    minDistance: minDistance
               ) {
                return
            }
            lastPointerLocation = point
            lastPointerUpdate = now
            effectLayer.pointer = point
            effectLayer.setNeedsDisplay()
        }
    }

    final class PointerWashLayer: CALayer {
        var pointer: CGPoint?
        var cornerRadiusValue: CGFloat = 24
        var intensity: Double = 1
        var isDark = false
        var isEffectEnabled = true

        override init() {
            super.init()
            needsDisplayOnBoundsChange = true
            drawsAsynchronously = true
        }

        override init(layer: Any) {
            super.init(layer: layer)
            if let layer = layer as? PointerWashLayer {
                pointer = layer.pointer
                cornerRadiusValue = layer.cornerRadiusValue
                intensity = layer.intensity
                isDark = layer.isDark
                isEffectEnabled = layer.isEffectEnabled
            }
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            needsDisplayOnBoundsChange = true
            drawsAsynchronously = true
        }

        override func draw(in context: CGContext) {
            guard isEffectEnabled,
                  let pointer,
                  bounds.width > 0,
                  bounds.height > 0 else { return }

            context.saveGState()
            let roundedPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadiusValue,
                cornerHeight: cornerRadiusValue,
                transform: nil
            )
            context.addPath(roundedPath)
            context.clip()

            let radius = max(max(bounds.width, bounds.height) * 0.42, 1)
            let strength = CGFloat(min(max(intensity, 0), 1.45))
            let firstAlpha = (isDark ? 0.20 : 0.48) * strength
            let secondAlpha = (isDark ? 0.06 : 0.15) * strength
            let colors = [
                NSColor.white.withAlphaComponent(firstAlpha).cgColor,
                NSColor.white.withAlphaComponent(secondAlpha).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0, 0.46, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: pointer,
                    startRadius: 0,
                    endCenter: pointer,
                    endRadius: radius,
                    options: [.drawsAfterEndLocation]
                )
            }

            context.restoreGState()
            context.saveGState()
            context.addPath(roundedPath)
            context.clip()

            let edgeAlpha = (isDark ? 0.30 : 0.66) * strength
            let edgeFadeAlpha = (isDark ? 0.08 : 0.18) * strength
            let edgeColors = [
                NSColor.white.withAlphaComponent(edgeAlpha).cgColor,
                NSColor.white.withAlphaComponent(edgeFadeAlpha).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            let opposite = CGPoint(x: bounds.width - pointer.x, y: bounds.height - pointer.y)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: edgeColors, locations: [0, 0.52, 1]) {
                context.setLineWidth(1.0 + strength * 0.45)
                context.addPath(roundedPath)
                context.replacePathWithStrokedPath()
                context.clip()
                context.drawLinearGradient(
                    gradient,
                    start: pointer,
                    end: opposite,
                    options: [.drawsAfterEndLocation]
                )
            }

            context.restoreGState()
        }
    }
}
