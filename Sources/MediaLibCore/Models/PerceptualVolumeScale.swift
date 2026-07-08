import Foundation

public enum PerceptualVolumeScale {
    private static let exponent: Double = 1.0

    public static func sliderValue(fromLinear volume: Double) -> Double {
        exponent == 1.0
            ? min(max(volume, 0), 1)
            : pow(min(max(volume, 0), 1), 1 / exponent)
    }

    public static func linearVolume(fromSlider value: Double) -> Double {
        exponent == 1.0
            ? min(max(value, 0), 1)
            : pow(min(max(value, 0), 1), exponent)
    }

    public static func adjustedVolume(
        _ volume: Float,
        direction: Int,
        sliderStep: Double = 0.055
    ) -> Float {
        let slider = sliderValue(fromLinear: Double(volume))
        let nextSlider = min(max(slider + Double(direction) * sliderStep, 0), 1)
        return Float(linearVolume(fromSlider: nextSlider))
    }
}
