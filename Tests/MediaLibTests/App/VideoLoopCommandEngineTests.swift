import XCTest
@testable import MediaLib

@MainActor
final class VideoLoopCommandEngineTests: XCTestCase {
    func testLoopCurrentItemMapsToMpvLoopFileValues() {
        let transport = FakeLoopCommandTransport()
        let engine = MpvVideoLoopCommandEngine(transport: transport)

        engine.setLoopCurrentItem(true)
        engine.setLoopCurrentItem(false)

        XCTAssertEqual(
            transport.writes,
            [
                .string(name: "loop-file", value: "inf"),
                .string(name: "loop-file", value: "no")
            ]
        )
    }

    func testABLoopClearsMissingBoundsWithNoSentinel() {
        let transport = FakeLoopCommandTransport()
        let engine = MpvVideoLoopCommandEngine(transport: transport)

        engine.setABLoop(start: nil, end: nil)

        XCTAssertEqual(
            transport.writes,
            [
                .string(name: "ab-loop-a", value: "no"),
                .string(name: "ab-loop-b", value: "no")
            ]
        )
    }

    func testABLoopPreservesStartOnlyAndRangeArguments() {
        let transport = FakeLoopCommandTransport()
        let engine = MpvVideoLoopCommandEngine(transport: transport)

        engine.setABLoop(start: 12.5, end: nil)
        engine.setABLoop(start: 12.5, end: 35.25)

        XCTAssertEqual(
            transport.writes,
            [
                .double(name: "ab-loop-a", value: 12.5),
                .string(name: "ab-loop-b", value: "no"),
                .double(name: "ab-loop-a", value: 12.5),
                .double(name: "ab-loop-b", value: 35.25)
            ]
        )
    }
}

@MainActor
private final class FakeLoopCommandTransport: MpvLoopCommandTransport {
    var writes: [RecordedLoopWrite] = []

    func setDouble(_ name: String, _ value: Double) {
        writes.append(.double(name: name, value: value))
    }

    func setString(_ name: String, _ value: String) {
        writes.append(.string(name: name, value: value))
    }
}

private enum RecordedLoopWrite: Equatable {
    case double(name: String, value: Double)
    case string(name: String, value: String)
}
