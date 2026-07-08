import XCTest
@testable import MediaLibCore

final class CyclicModePolicyTests: XCTestCase {
    func testNextAdvancesToFollowingMode() {
        XCTAssertEqual(
            CyclicModePolicy.next(after: TestMode.off, in: TestMode.allCases),
            .low
        )
    }

    func testNextWrapsLastModeToFirstMode() {
        XCTAssertEqual(
            CyclicModePolicy.next(after: TestMode.high, in: TestMode.allCases),
            .off
        )
    }

    func testNextFallsBackToFirstModeWhenCurrentModeIsMissing() {
        XCTAssertEqual(
            CyclicModePolicy.next(after: TestMode.high, in: [TestMode.off, .low]),
            .off
        )
    }

    func testNextKeepsCurrentModeWhenCollectionIsEmpty() {
        XCTAssertEqual(
            CyclicModePolicy.next(after: TestMode.low, in: [TestMode]()),
            .low
        )
    }

    func testNextSupportsCollectionsWithNonZeroStartIndex() {
        let modes = TestMode.allCases[1...3]

        XCTAssertEqual(
            CyclicModePolicy.next(after: TestMode.high, in: modes),
            .low
        )
    }

    func testPreviousMovesToEarlierMode() {
        XCTAssertEqual(
            CyclicModePolicy.previous(after: TestMode.medium, in: TestMode.allCases),
            .low
        )
    }

    func testPreviousWrapsFirstModeToLastMode() {
        XCTAssertEqual(
            CyclicModePolicy.previous(after: TestMode.off, in: TestMode.allCases),
            .high
        )
    }

    func testPreviousFallsBackToFirstModeWhenCurrentModeIsMissing() {
        XCTAssertEqual(
            CyclicModePolicy.previous(after: TestMode.high, in: [TestMode.off, .low]),
            .off
        )
    }

    func testPreviousKeepsCurrentModeWhenCollectionIsEmpty() {
        XCTAssertEqual(
            CyclicModePolicy.previous(after: TestMode.low, in: [TestMode]()),
            .low
        )
    }

    func testPreviousSupportsCollectionsWithNonZeroStartIndex() {
        let modes = TestMode.allCases[1...3]

        XCTAssertEqual(
            CyclicModePolicy.previous(after: TestMode.low, in: modes),
            .high
        )
    }
}

private enum TestMode: CaseIterable, Equatable {
    case off
    case low
    case medium
    case high
}
