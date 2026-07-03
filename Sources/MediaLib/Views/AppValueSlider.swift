import SwiftUI

struct AppValueSlider: View {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    var step: Double = 0
    var tint: Color = AppColors.selectedGlassTint
    var accessibilityLabel: String = "滑条"

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = normalizedProgress
            let thumbSide = isDragging || isHovering ? 17.5 : 15.5
            let trackHeight: CGFloat = 7
            let shape = Capsule()

            ZStack(alignment: .leading) {
                shape
                    .fill(trackBackground)
                    .overlay {
                        shape.strokeBorder(AppColors.refCardBorder.opacity(colorScheme == .dark ? 0.42 : 0.34), lineWidth: 0.55)
                    }
                    .frame(height: trackHeight)

                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(isEnabled ? 0.95 : 0.32),
                                AppColors.referenceCyan.opacity(isEnabled ? 0.86 : 0.28)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, width * progress), height: trackHeight)
                    .overlay(alignment: .topLeading) {
                        Capsule()
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.36))
                            .frame(height: 2)
                            .padding(.horizontal, 2)
                    }

                Circle()
                    .fill(thumbFill)
                    .frame(width: thumbSide, height: thumbSide)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.36 : 0.82), lineWidth: 0.85)
                    }
                    .shadow(color: tint.opacity(isEnabled ? 0.22 : 0), radius: isDragging ? 8 : 5, y: isDragging ? 3 : 2)
                    .position(x: min(max(width * progress, thumbSide / 2), width - thumbSide / 2), y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        updateValue(locationX: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        updateValue(locationX: gesture.location.x, width: width)
                        isDragging = false
                    }
            )
            .opacity(isEnabled ? 1 : AppControlMetrics.disabledControlOpacity)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isDragging)
        }
        .frame(height: 28)
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let delta = step > 0 ? step : (bounds.upperBound - bounds.lowerBound) / 20
            switch direction {
            case .increment:
                value = snapped(value + delta)
            case .decrement:
                value = snapped(value - delta)
            @unknown default:
                break
            }
        }
    }

    private var normalizedProgress: CGFloat {
        let span = max(bounds.upperBound - bounds.lowerBound, .ulpOfOne)
        let raw = (value - bounds.lowerBound) / span
        return CGFloat(min(max(raw, 0), 1))
    }

    private var trackBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                AppColors.refScanFill.opacity(colorScheme == .dark ? 0.62 : 0.92),
                AppColors.refCardBg.opacity(colorScheme == .dark ? 0.26 : 0.72)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var thumbFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.82 : 0.98),
                tint.opacity(colorScheme == .dark ? 0.30 : 0.14)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var accessibilityValue: String {
        let progress = Int((normalizedProgress * 100).rounded())
        return "\(progress)%"
    }

    private func updateValue(locationX: CGFloat, width: CGFloat) {
        guard isEnabled else { return }
        let clampedX = min(max(locationX, 0), width)
        let ratio = Double(clampedX / max(width, 1))
        value = snapped(bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * ratio)
    }

    private func snapped(_ candidate: Double) -> Double {
        let clamped = min(max(candidate, bounds.lowerBound), bounds.upperBound)
        guard step > 0 else { return clamped }
        let units = ((clamped - bounds.lowerBound) / step).rounded()
        return min(max(bounds.lowerBound + units * step, bounds.lowerBound), bounds.upperBound)
    }
}
