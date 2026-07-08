import AVFoundation
import XCTest
@testable import MediaLib

@MainActor
final class MusicPlaybackEngineTests: XCTestCase {
    func testPlaybackStateProjectsFromTransport() throws {
        let transport = FakeMusicPlayerTransport()
        let engine = AVQueueMusicPlaybackEngine(transport: transport)

        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertFalse(engine.isPlaying)
        let currentTimeSeconds = try XCTUnwrap(engine.currentTimeSeconds)
        XCTAssertEqual(currentTimeSeconds, 3.25, accuracy: 0.0001)

        transport.currentItem = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/song.m4a"))
        transport.rate = 1.2

        XCTAssertTrue(engine.hasCurrentItem)
        XCTAssertTrue(engine.isPlaying)
    }

    func testPlaybackCommandsDelegateToTransport() {
        let transport = FakeMusicPlayerTransport()
        let engine = AVQueueMusicPlaybackEngine(transport: transport)

        engine.playImmediately(atRate: 1.5)
        engine.pause()

        XCTAssertEqual(transport.playRates, [1.5])
        XCTAssertEqual(transport.pauseCount, 1)
        XCTAssertEqual(transport.rate, 0)
    }

    func testSeekUsesPreciseZeroTolerance() {
        let transport = FakeMusicPlayerTransport()
        let engine = AVQueueMusicPlaybackEngine(transport: transport)

        engine.seek(to: 42.5) { _ in }
        engine.seekToStart { _ in }

        XCTAssertEqual(transport.seeks.count, 2)
        XCTAssertEqual(transport.seeks[0].time.seconds, 42.5, accuracy: 0.0001)
        XCTAssertEqual(transport.seeks[0].toleranceBefore, .zero)
        XCTAssertEqual(transport.seeks[0].toleranceAfter, .zero)
        XCTAssertEqual(transport.seeks[1].time, .zero)
        XCTAssertEqual(transport.completionResults, [true, true])
    }

    func testVolumeIsClampedAndMuteIsForwarded() {
        let transport = FakeMusicPlayerTransport()
        let engine = AVQueueMusicPlaybackEngine(transport: transport)

        engine.setVolume(1.4)
        XCTAssertEqual(transport.volume, 1)

        engine.setVolume(-0.25)
        XCTAssertEqual(transport.volume, 0)

        engine.setMuted(false)
        XCTAssertFalse(transport.isMuted)
    }
}

@MainActor
private final class FakeMusicPlayerTransport: MusicPlayerTransport {
    var currentItem: AVPlayerItem?
    var rate: Float = 0
    var volume: Float = 0.5
    var isMuted = true
    var currentTimeValue = CMTime(seconds: 3.25, preferredTimescale: 600)
    var pauseCount = 0
    var playRates: [Float] = []
    var seeks: [RecordedMusicSeek] = []
    var completionResults: [Bool] = []

    func currentTime() -> CMTime {
        currentTimeValue
    }

    func pause() {
        pauseCount += 1
        rate = 0
    }

    func playImmediately(atRate rate: Float) {
        playRates.append(rate)
        self.rate = rate
    }

    func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        seeks.append(
            RecordedMusicSeek(
                time: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter
            )
        )
        currentTimeValue = time
        completionResults.append(true)
        completionHandler(true)
    }
}

private struct RecordedMusicSeek {
    let time: CMTime
    let toleranceBefore: CMTime
    let toleranceAfter: CMTime
}
