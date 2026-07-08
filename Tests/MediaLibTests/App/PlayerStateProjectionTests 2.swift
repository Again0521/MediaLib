import XCTest
@testable import MediaLib

@MainActor
final class PlayerStateProjectionTests: XCTestCase {
    func testProjectionMapsGenericPlayerStateSource() async throws {
        let source = FakePlayerStateSource()
        let projection = PlayerStateProjection(controller: source) { $0.counter }

        XCTAssertEqual(projection.value, 0)

        source.counter = 3
        try await waitForProjectionRefresh()

        XCTAssertEqual(projection.value, 3)
    }

    func testProjectionIgnoresUpdatesWhileInactiveAndRefreshesWhenReactivated() async throws {
        let source = FakePlayerStateSource()
        let projection = PlayerStateProjection(controller: source) { $0.counter }

        projection.setActive(false)
        source.counter = 5
        try await waitForProjectionRefresh()
        XCTAssertEqual(projection.value, 0)

        projection.setActive(true)
        XCTAssertEqual(projection.value, 5)
    }

    func testProjectionKeepsExistingControllerTypeAliasForMpvController() {
        let controller = MpvPlayerController()
        let projection = PlayerControllerProjection(controller: controller) { $0.currentTime }

        XCTAssertEqual(projection.value, 0)
    }

    private func waitForProjectionRefresh() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@MainActor
private final class FakePlayerStateSource: PlayerStateProjecting {
    @Published var counter = 0
}
