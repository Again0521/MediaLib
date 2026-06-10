import AppKit
import SwiftUI

enum MusicGlassSurfaceRole: Hashable {
    case lyrics
    case controls
    case chrome
    case popover
    case mini

    var usesNeutralFloatingMaterial: Bool {
        switch self {
        case .lyrics, .controls, .chrome:
            return true
        case .popover, .mini:
            return false
        }
    }

    func materialOpacity(dark: Bool, centerClarity: Bool) -> Double {
        if centerClarity {
            return dark ? 0.58 : 0.46
        }
        switch self {
        case .lyrics:
            return dark ? 0.60 : 0.50
        case .controls:
            return dark ? 0.61 : 0.52
        case .chrome:
            return dark ? 0.60 : 0.50
        case .popover:
            return dark ? 0.70 : 0.62
        case .mini:
            return dark ? 0.72 : 0.64
        }
    }

    func neutralTintOpacity(dark: Bool) -> Double {
        switch self {
        case .lyrics:
            return dark ? 0.022 : 0.0
        case .controls:
            return dark ? 0.024 : 0.0
        case .chrome:
            return dark ? 0.022 : 0.0
        case .popover:
            return dark ? 0.032 : 0.002
        case .mini:
            return dark ? 0.040 : 0.004
        }
    }

    func albumTintOpacity(dark: Bool) -> Double {
        if usesNeutralFloatingMaterial { return 0 }
        switch self {
        case .lyrics:
            return dark ? 0.285 : 0.175
        case .controls:
            return dark ? 0.265 : 0.160
        case .chrome:
            return dark ? 0.255 : 0.150
        case .popover:
            return dark ? 0.205 : 0.125
        case .mini:
            return dark ? 0.120 : 0.075
        }
    }

    func textureMultiplier(centerClarity: Bool) -> Double {
        if centerClarity { return 0.74 }
        switch self {
        case .lyrics:
            return 0.88
        case .controls:
            return 0.84
        case .chrome:
            return 0.80
        case .popover:
            return 0.70
        case .mini:
            return 0.52
        }
    }

    var effectIntensity: Double {
        switch self {
        case .lyrics: return 1.02
        case .controls: return 0.96
        case .chrome: return 0.92
        case .popover: return 0.76
        case .mini: return 0.72
        }
    }

    var edgeDepth: Double {
        switch self {
        case .lyrics: return 1.20
        case .controls: return 1.00
        case .chrome: return 0.92
        case .popover: return 0.70
        case .mini: return 0.42
        }
    }

    var shadowColorRadius: CGFloat {
        switch self {
        case .lyrics: return 20
        case .controls: return 17
        case .chrome: return 15
        case .popover: return 14
        case .mini: return 12
        }
    }

    var shadowDepthRadius: CGFloat {
        switch self {
        case .lyrics: return 13
        case .controls: return 11
        case .chrome: return 10
        case .popover: return 9
        case .mini: return 8
        }
    }

    func shadowColorOpacity(dark: Bool) -> Double {
        switch self {
        case .lyrics:
            return dark ? 0.24 : 0.18
        case .controls:
            return dark ? 0.21 : 0.15
        case .chrome:
            return dark ? 0.19 : 0.13
        case .popover:
            return dark ? 0.16 : 0.10
        case .mini:
            return dark ? 0.11 : 0.060
        }
    }

    func shadowDepthOpacity(dark: Bool) -> Double {
        switch self {
        case .lyrics:
            return dark ? 0.18 : 0.078
        case .controls:
            return dark ? 0.16 : 0.066
        case .chrome:
            return dark ? 0.14 : 0.056
        case .popover:
            return dark ? 0.12 : 0.046
        case .mini:
            return dark ? 0.08 : 0.032
        }
    }
}

struct LyricsCardEffectLayerView: NSViewRepresentable {
    let cornerRadius: CGFloat
    let intensity: Double
    let colorScheme: ColorScheme
    let isEnabled: Bool
    var edgeDepth: Double = 1
    var tintColor: NSColor = .white
    var centerClarity = false
    var role: MusicGlassSurfaceRole = .lyrics

    func makeNSView(context: Context) -> EffectView {
        let view = EffectView(frame: .zero)
        view.update(
            cornerRadius: cornerRadius,
            intensity: intensity,
            colorScheme: colorScheme,
            isEnabled: isEnabled,
            edgeDepth: edgeDepth,
            tintColor: tintColor,
            centerClarity: centerClarity,
            role: role
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
            centerClarity: centerClarity,
            role: role
        )
    }

    final class EffectView: NSView {
        private let staticLayer = StaticGlassLayer()
        private let pointerLayer = PointerHighlightLayer()
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
            for layer in [staticLayer, pointerLayer] {
                layer.frame = bounds
                layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                layer.setNeedsDisplay()
            }
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
            pointerLayer.pointer = nil
            pointerLayer.setNeedsDisplay()
        }

        func update(
            cornerRadius: CGFloat,
            intensity: Double,
            colorScheme: ColorScheme,
            isEnabled: Bool,
            edgeDepth: Double,
            tintColor: NSColor,
            centerClarity: Bool,
            role: MusicGlassSurfaceRole
        ) {
            let resolvedTint = tintColor.usingColorSpace(.deviceRGB) ?? tintColor
            let resolvedIntensity = min(max(intensity, 0), 1.45)
            let resolvedEdgeDepth = min(max(edgeDepth, 0), 1.6)
            for layer in [staticLayer, pointerLayer] {
                layer.cornerRadiusValue = cornerRadius
                layer.intensity = resolvedIntensity
                layer.isDark = colorScheme == .dark
                layer.edgeDepth = resolvedEdgeDepth
                layer.tintColor = resolvedTint
                layer.centerClarity = centerClarity
                layer.role = role
            }
            pointerLayer.isEffectEnabled = isEnabled
            if !isEnabled {
                lastPointerLocation = nil
                pointerLayer.pointer = nil
            }
            staticLayer.setNeedsDisplay()
            pointerLayer.setNeedsDisplay()
        }

        private func configure() {
            wantsLayer = true
            layer?.masksToBounds = false
            for effectLayer in [staticLayer, pointerLayer] {
                effectLayer.masksToBounds = false
                effectLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                layer?.addSublayer(effectLayer)
            }
        }

        private func updatePointer(with event: NSEvent, force: Bool) {
            guard pointerLayer.isEffectEnabled, bounds.width > 0, bounds.height > 0 else { return }
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
            pointerLayer.pointer = point
            pointerLayer.setNeedsDisplay()
        }
    }

    class BaseGlassLayer: CALayer {
        var cornerRadiusValue: CGFloat = 24
        var intensity: Double = 1
        var isDark = false
        var edgeDepth: Double = 1
        var tintColor: NSColor = .white
        var centerClarity = false
        var role: MusicGlassSurfaceRole = .lyrics

        override init() {
            super.init()
            isOpaque = false
            needsDisplayOnBoundsChange = true
            drawsAsynchronously = true
        }

        override init(layer: Any) {
            super.init(layer: layer)
            if let layer = layer as? BaseGlassLayer {
                cornerRadiusValue = layer.cornerRadiusValue
                intensity = layer.intensity
                isDark = layer.isDark
                edgeDepth = layer.edgeDepth
                tintColor = layer.tintColor
                centerClarity = layer.centerClarity
                role = layer.role
            }
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isOpaque = false
            needsDisplayOnBoundsChange = true
            drawsAsynchronously = true
        }

        func tinted(_ amount: CGFloat, alpha: CGFloat) -> CGColor {
            let t = min(max(amount, 0), 1)
            let red = 1 - (1 - tintColor.redComponent) * t
            let green = 1 - (1 - tintColor.greenComponent) * t
            let blue = 1 - (1 - tintColor.blueComponent) * t
            return NSColor(deviceRed: red, green: green, blue: blue, alpha: min(max(alpha, 0), 1)).cgColor
        }
    }

    final class StaticGlassLayer: BaseGlassLayer {
        override func draw(in context: CGContext) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            context.clear(bounds)
            let roundedPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadiusValue,
                cornerHeight: cornerRadiusValue,
                transform: nil
            )
            context.saveGState()
            context.addPath(roundedPath)
            context.clip()
            drawStaticGlass(in: context, path: roundedPath)
            context.restoreGState()
        }

        private func drawStaticGlass(in context: CGContext, path roundedPath: CGPath) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let strength = CGFloat(min(max(intensity, 0), 1.45))
            let depth = CGFloat(min(max(edgeDepth, 0), 1.6))
            let clarity = centerClarity ? CGFloat(0.52) : CGFloat(1.0)
            let shade = centerClarity ? CGFloat(0.56) : CGFloat(1.0)
            let upperTransition = centerClarity ? CGFloat(0.24) : CGFloat(0.16)
            let clearStart = centerClarity ? CGFloat(0.38) : CGFloat(0.36)
            let clearEnd = centerClarity ? CGFloat(0.62) : CGFloat(0.62)
            let lowerTransition = centerClarity ? CGFloat(0.76) : CGFloat(0.82)

            context.setBlendMode(.screen)
            let verticalScale: CGFloat = {
                switch role {
                case .lyrics: return 1.00
                case .controls: return 0.88
                case .chrome: return 0.82
                case .popover: return 0.70
                case .mini: return 0.50
                }
            }()
            let verticalColors = [
                tinted(0.30, alpha: (isDark ? 0.044 : 0.088) * strength * depth * verticalScale),
                tinted(0.20, alpha: (isDark ? 0.014 : 0.020) * strength * depth * clarity * verticalScale),
                NSColor.white.withAlphaComponent(0).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
                tinted(0.26, alpha: (isDark ? 0.016 : 0.020) * strength * depth * clarity * verticalScale),
                tinted(0.34, alpha: (isDark ? 0.040 : 0.052) * strength * depth * verticalScale)
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

            let sideReach: CGFloat = {
                switch role {
                case .lyrics: return 0.42
                case .controls: return 0.34
                case .chrome: return 0.46
                case .popover: return 0.30
                case .mini: return 0.20
                }
            }()
            let leftColors = [
                tinted(0.70, alpha: (isDark ? 0.105 : 0.082) * strength * depth * verticalScale),
                tinted(0.48, alpha: (isDark ? 0.040 : 0.030) * strength * depth * verticalScale),
                NSColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: leftColors, locations: [0.0, 0.14, 1.0]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: bounds.minX, y: bounds.midY),
                    end: CGPoint(x: bounds.minX + bounds.width * sideReach, y: bounds.midY),
                    options: [.drawsAfterEndLocation]
                )
            }

            context.setBlendMode(.normal)
            let innerShadeColors = [
                NSColor.clear.cgColor,
                NSColor.black.withAlphaComponent((isDark ? 0.020 : 0.004) * strength * depth * shade).cgColor,
                NSColor.black.withAlphaComponent((isDark ? 0.056 : 0.012) * strength * depth).cgColor
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
            let strokeScale: CGFloat = role == .mini ? 0.58 : 1.0
            let strokeColors = [
                tinted(0.32, alpha: (isDark ? 0.28 : 0.54) * strength * strokeScale),
                tinted(0.54, alpha: (isDark ? 0.15 : 0.22) * strength * strokeScale),
                NSColor.white.withAlphaComponent((isDark ? 0.052 : 0.105) * strength * strokeScale).cgColor
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

final class PointerHighlightLayer: BaseGlassLayer {
    var pointer: CGPoint?
    var isEffectEnabled = true

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let layer = layer as? PointerHighlightLayer {
            pointer = layer.pointer
            isEffectEnabled = layer.isEffectEnabled
            }
        }

        override func draw(in context: CGContext) {
            context.clear(bounds)
            guard bounds.width > 0,
                  bounds.height > 0,
                  isEffectEnabled,
                  let pointer else { return }

            let roundedPath = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadiusValue,
                cornerHeight: cornerRadiusValue,
                transform: nil
            )
            context.saveGState()
            context.addPath(roundedPath)
            context.clip()

            let strength = CGFloat(min(max(intensity, 0), 1.45))
            let roleScale: CGFloat = {
                switch role {
                case .lyrics: return 1.00
                case .controls: return 0.88
                case .chrome: return 0.82
                case .popover: return 0.70
                case .mini: return 0.52
                }
            }()
            let radius = max(max(bounds.width, bounds.height) * (role == .mini ? 0.34 : 0.42), 1)
            let firstAlpha = (isDark ? 0.18 : 0.34) * strength * roleScale
            let secondAlpha = (isDark ? 0.055 : 0.110) * strength * roleScale
            let colors = [
                tinted(0.22, alpha: firstAlpha),
                tinted(0.44, alpha: secondAlpha),
                NSColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.46, 1]) {
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

            let edgeAlpha = (isDark ? 0.28 : 0.48) * strength * roleScale
            let edgeFadeAlpha = (isDark ? 0.075 : 0.130) * strength * roleScale
            let edgeColors = [
                tinted(0.58, alpha: edgeAlpha),
                tinted(0.70, alpha: edgeFadeAlpha),
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
