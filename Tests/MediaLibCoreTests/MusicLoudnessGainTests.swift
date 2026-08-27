import XCTest
@testable import MediaLibCore

// 响度均衡增益计算回归测试（音频正确性，此前零覆盖）：MusicLoudnessGain.linearGain 把 ReplayGain 的 dB 增益
// 换算成线性音量，并受峰值约束防止削波、绝对上限 4。锁定 dB→线性、峰值限幅、track/album 回退、关闭等语义。
final class MusicLoudnessGainTests: XCTestCase {
    private func gain(
        _ mode: MusicLoudnessNormalization,
        track: Double? = nil, album: Double? = nil,
        trackPeak: Double? = nil, albumPeak: Double? = nil
    ) -> Float {
        MusicLoudnessGain.linearGain(
            mode: mode, trackGainDB: track, albumGainDB: album,
            trackPeak: trackPeak, albumPeak: albumPeak
        )
    }

    func testOffAlwaysReturnsUnityGain() {
        XCTAssertEqual(gain(.off, track: 6, album: 6, trackPeak: 0.5), 1.0, accuracy: 1e-5)
    }

    func testZeroDBIsUnity() {
        XCTAssertEqual(gain(.track, track: 0), 1.0, accuracy: 1e-5)
    }

    func testNegativeGainAttenuatesWithoutPeak() {
        // -6dB → 10^(-0.3) ≈ 0.5012；衰减不受「无峰值时上限 1」限制。
        XCTAssertEqual(gain(.track, track: -6), Float(pow(10, -6.0 / 20)), accuracy: 1e-4)
    }

    func testPositiveGainWithoutPeakIsCappedAtUnity() {
        // +6dB 想要 ~1.995，但没有峰值信息时上限取 min(requested, 1) = 1，避免盲目提升导致削波。
        XCTAssertEqual(gain(.track, track: 6), 1.0, accuracy: 1e-5)
    }

    func testPositiveGainAllowedUpToPeakHeadroom() {
        // +6dB + 峰值 0.5 → peakLimit = 1/0.5 = 2，允许提升到 ~1.995。
        XCTAssertEqual(gain(.track, track: 6, trackPeak: 0.5), Float(pow(10, 6.0 / 20)), accuracy: 1e-4)
    }

    func testGainClampedToAbsoluteMaxFour() {
        // 极大增益 + 充足峰值余量 → 仍被绝对上限 4 钳住。
        XCTAssertEqual(gain(.track, track: 40, trackPeak: 0.01), 4.0, accuracy: 1e-5)
    }

    func testNilGainReturnsUnity() {
        XCTAssertEqual(gain(.track, track: nil, album: nil), 1.0, accuracy: 1e-5)
    }

    func testNonFiniteGainReturnsUnity() {
        XCTAssertEqual(gain(.track, track: .infinity), 1.0, accuracy: 1e-5)
    }

    func testTrackModeFallsBackToAlbumValues() {
        // .track 缺单曲增益时回退专辑增益；-6dB 应被采用。
        XCTAssertEqual(gain(.track, track: nil, album: -6), Float(pow(10, -6.0 / 20)), accuracy: 1e-4)
    }

    func testAlbumModePrefersAlbumGain() {
        // .album 优先用专辑增益（-6dB 衰减），而非单曲增益。
        XCTAssertEqual(gain(.album, track: 6, album: -6), Float(pow(10, -6.0 / 20)), accuracy: 1e-4)
    }
}
