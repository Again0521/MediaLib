import AppKit
import SwiftUI

struct LyricsCardEffectLayerView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let intensity: Double
    let colorScheme: ColorScheme
    let isEnabled: Bool
    var edgeDepth: Double = 1
    // 玻璃边缘染色：指针扫过卡片时的方向性边缘高光不再是死白，而是混入专辑主色，
    // 与展开播放器整体的 Liquid Glass 染边语言一致（spec：边缘不要死白，要混入专辑主色）。
    var tintColor: NSColor = .white
    var centerClarity = false

    func makeNSView(context: Context) -> EffectView {
        let view = EffectView(frame: .zero)
        view.update(
            cornerRadius: cornerRadius,
            intensity: intensity,
            colorScheme: colorScheme,
            isEnabled: isEnabled,
            edgeDepth: edgeDepth,
            tintColor: tintColor,
            centerClarity: centerClarity
        )
        return view
    }

    func updateNSView(_ nsView: EffectView, context: Context) {
        nsView.update(
            cornerRadius: cornerRadius,
            intensity: intensity,
            colorScheme: colorScheme,
            isEnabled: isEnabled,
            edgeDepth: edgeDepth,
            tintColor: tintColor,
            centerClarity: centerClarity
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
            isEnabled: Bool,
            edgeDepth: Double,
            tintColor: NSColor,
            centerClarity: Bool
        ) {
            effectLayer.cornerRadiusValue = cornerRadius
            effectLayer.intensity = min(max(intensity, 0), 1.45)
            effectLayer.isDark = colorScheme == .dark
            effectLayer.isEffectEnabled = isEnabled
            effectLayer.edgeDepth = min(max(edgeDepth, 0), 1.6)
            effectLayer.tintColor = tintColor.usingColorSpace(.deviceRGB) ?? tintColor
            effectLayer.centerClarity = centerClarity
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
        var edgeDepth: Double = 1
        var tintColor: NSColor = .white
        var centerClarity = false

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
                edgeDepth = layer.edgeDepth
                tintColor = layer.tintColor
                centerClarity = layer.centerClarity
            }
        }

        /// 把白色高光按 amount 比例向专辑主色混合：amount=0 纯白，amount=1 纯专辑色。
        /// 中心扫光仍偏白（保留磨砂玻璃的通透高光），方向性边缘描边混入更多专辑色（不死白）。
        private func tinted(_ amount: CGFloat, alpha: CGFloat) -> CGColor {
            let t = min(max(amount, 0), 1)
            let red = 1 - (1 - tintColor.redComponent) * t
            let green = 1 - (1 - tintColor.greenComponent) * t
            let blue = 1 - (1 - tintColor.blueComponent) * t
            return NSColor(deviceRed: red, green: green, blue: blue, alpha: min(max(alpha, 0), 1)).cgColor
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            needsDisplayOnBoundsChange = true
            drawsAsynchronously = true
        }

        override func draw(in context: CGContext) {
            guard bounds.width > 0,
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

            let strength = CGFloat(min(max(intensity, 0), 1.45))
            let depth = CGFloat(min(max(edgeDepth, 0), 1.6))
            drawStaticGlass(in: context, path: roundedPath, strength: strength, depth: depth)

            guard isEffectEnabled, let pointer else {
                context.restoreGState()
                return
            }

            let radius = max(max(bounds.width, bounds.height) * 0.42, 1)
            let firstAlpha = (isDark ? 0.20 : 0.48) * strength
            let secondAlpha = (isDark ? 0.06 : 0.15) * strength
            // 中心扫光保持偏白通透（仅外圈微染专辑色），避免高光发灰、发脏。
            let colors = [
                tinted(0.05, alpha: firstAlpha),
                tinted(0.22, alpha: secondAlpha),
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
            // 方向性边缘描边混入更多专辑主色（近指针端染色更明显），让玻璃边沿不死白、带专辑色折射感。
            let edgeColors = [
                tinted(0.42, alpha: edgeAlpha),
                tinted(0.58, alpha: edgeFadeAlpha),
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

        private func drawStaticGlass(in context: CGContext, path roundedPath: CGPath, strength: CGFloat, depth: CGFloat) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let middleClarity = centerClarity ? CGFloat(0.72) : CGFloat(1.0)
            let middleShade = centerClarity ? CGFloat(0.70) : CGFloat(1.0)
            let upperTransition = centerClarity ? CGFloat(0.22) : CGFloat(0.16)
            let clearStart = centerClarity ? CGFloat(0.42) : CGFloat(0.36)
            let clearEnd = centerClarity ? CGFloat(0.58) : CGFloat(0.62)
            let lowerTransition = centerClarity ? CGFloat(0.78) : CGFloat(0.82)

            context.setBlendMode(.screen)
            let verticalColors = [
                tinted(0.18, alpha: (isDark ? 0.050 : 0.088) * strength * depth),
                tinted(0.10, alpha: (isDark ? 0.026 : 0.050) * strength * depth * middleClarity),
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
                tinted(0.16, alpha: (isDark ? 0.030 : 0.050) * strength * depth * middleClarity),
                tinted(0.22, alpha: (isDark ? 0.048 : 0.078) * strength * depth)
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: verticalColors,
                locations: [0.0, upperTransition, clearStart, clearEnd, lowerTransition, 1.0]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.midX, y: bounds.minY),
                    end: CGPoint(x: bounds.midX, y: bounds.maxY),
                    options: []
                )
            }

            let leftColors = [
                tinted(0.70, alpha: (isDark ? 0.135 : 0.115) * strength * depth),
                tinted(0.48, alpha: (isDark ? 0.052 : 0.044) * strength * depth),
                NSColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: leftColors, locations: [0.0, 0.18, 1.0]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.minX, y: bounds.midY),
                    end: CGPoint(x: bounds.minX + bounds.width * 0.42, y: bounds.midY),
                    options: [.drawsAfterEndLocation]
                )
            }

            context.setBlendMode(.normal)
            let innerShadeColors = [
                NSColor.clear.cgColor,
                NSColor.black.withAlphaComponent((isDark ? 0.030 : 0.018) * strength * depth * middleShade).cgColor,
                NSColor.black.withAlphaComponent((isDark ? 0.085 : 0.040) * strength * depth).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: innerShadeColors, locations: [0.0, 0.70, 1.0]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.midX, y: bounds.minY),
                    end: CGPoint(x: bounds.midX, y: bounds.maxY),
                    options: []
                )
            }

            context.setBlendMode(.screen)
            let strokeColors = [
                tinted(0.26, alpha: (isDark ? 0.30 : 0.48) * strength),
                tinted(0.56, alpha: (isDark ? 0.16 : 0.20) * strength),
                NSColor.white.withAlphaComponent((isDark ? 0.08 : 0.16) * strength).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: strokeColors, locations: [0.0, 0.48, 1.0]) {
                context.saveGState()
                context.setLineWidth(1.0)
                context.addPath(roundedPath)
                context.replacePathWithStrokedPath()
                context.clip()
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.minX, y: bounds.minY),
                    end: CGPoint(x: bounds.maxX, y: bounds.maxY),
                    options: []
                )
                context.restoreGState()
            }
        }
    }
}
