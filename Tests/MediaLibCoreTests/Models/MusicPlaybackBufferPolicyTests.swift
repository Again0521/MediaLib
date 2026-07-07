import XCTest
@testable import MediaLibCore

final class MusicPlaybackBufferPolicyTests: XCTestCase {
    func testAutomaticallyWaitsOnlyForNetworkSources() {
        XCTAssertTrue(MusicPlaybackBufferPolicy.automaticallyWaitsToMinimizeStalling(isNetwork: true))
        XCTAssertFalse(MusicPlaybackBufferPolicy.automaticallyWaitsToMinimizeStalling(isNetwork: false))
    }

    func testPreferredForwardBufferDurationKeepsExistingLocalAndNetworkValues() {
        XCTAssertEqual(
            MusicPlaybackBufferPolicy.preferredForwardBufferDuration(isNetwork: true, preloaded: false),
            12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MusicPlaybackBufferPolicy.preferredForwardBufferDuration(isNetwork: true, preloaded: true),
            30,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MusicPlaybackBufferPolicy.preferredForwardBufferDuration(isNetwork: false, preloaded: false),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MusicPlaybackBufferPolicy.preferredForwardBufferDuration(isNetwork: false, preloaded: true),
            120,
            accuracy: 0.0001
        )
    }

    func testPreciseTimingIsUsedOnlyForNonNetworkMusicSources() {
        XCTAssertTrue(MusicPlaybackBufferPolicy.prefersPreciseTiming(isNetwork: false, isMusic: true))
        XCTAssertFalse(MusicPlaybackBufferPolicy.prefersPreciseTiming(isNetwork: true, isMusic: true))
        XCTAssertFalse(MusicPlaybackBufferPolicy.prefersPreciseTiming(isNetwork: false, isMusic: false))
    }
}
