import Foundation
import XCTest
@testable import MediaLib

@MainActor
final class MpvSnapshotReadCoordinatorTests: XCTestCase {
    func testLateOldReaderCompletionCannotReleaseNewRead() {
        let coordinator = MpvSnapshotReadCoordinator()
        let oldReader = NSObject()
        let newReader = NSObject()
        let old = coordinator.begin(reader: oldReader, playbackGeneration: 1, forceTrackRefresh: false)!

        coordinator.invalidate()
        let current = coordinator.begin(reader: newReader, playbackGeneration: 2, forceTrackRefresh: false)!
        XCTAssertFalse(coordinator.complete(old, currentReader: newReader, playbackGeneration: 2))
        XCTAssertNil(coordinator.begin(reader: newReader, playbackGeneration: 2, forceTrackRefresh: false))
        XCTAssertTrue(coordinator.complete(current, currentReader: newReader, playbackGeneration: 2))
        XCTAssertNotNil(coordinator.begin(reader: newReader, playbackGeneration: 2, forceTrackRefresh: false))
    }

    func testInvalidationRejectsOldCompletionEvenWhenReaderAndGenerationAreReused() {
        let coordinator = MpvSnapshotReadCoordinator()
        let reader = NSObject()
        let old = coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false)!

        coordinator.invalidate()
        let current = coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false)!
        XCTAssertNotEqual(old, current)
        XCTAssertFalse(coordinator.complete(old, currentReader: reader, playbackGeneration: 1))
        XCTAssertNil(coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false))
        XCTAssertTrue(coordinator.complete(current, currentReader: reader, playbackGeneration: 1))
    }

    func testForcedTrackRefreshIsCoalescedAcrossInFlightRead() {
        let coordinator = MpvSnapshotReadCoordinator()
        let reader = NSObject()
        let first = coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false)!
        XCTAssertFalse(first.forceTrackRefresh)

        XCTAssertNil(coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: true))
        XCTAssertNil(coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: true))
        XCTAssertTrue(coordinator.forceTrackRefreshPending)
        XCTAssertTrue(coordinator.complete(first, currentReader: reader, playbackGeneration: 1))

        let forced = coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false)!
        XCTAssertTrue(forced.forceTrackRefresh)
        XCTAssertFalse(coordinator.forceTrackRefreshPending)
        XCTAssertTrue(coordinator.complete(forced, currentReader: reader, playbackGeneration: 1))
    }

    func testCompletionRequiresCurrentReaderAndGeneration() {
        let coordinator = MpvSnapshotReadCoordinator()
        let reader = NSObject()
        let otherReader = NSObject()
        let wrongReader = coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false)!
        XCTAssertFalse(coordinator.complete(wrongReader, currentReader: otherReader, playbackGeneration: 1))

        let wrongGeneration = coordinator.begin(reader: reader, playbackGeneration: 1, forceTrackRefresh: false)!
        XCTAssertFalse(coordinator.complete(wrongGeneration, currentReader: reader, playbackGeneration: 2))
    }
}
