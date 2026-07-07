import XCTest
@testable import MediaLib

final class EmbyServiceQueryPolicyTests: XCTestCase {
    func testMediaSourceIDParsesQueryNameCaseInsensitively() {
        XCTAssertEqual(
            EmbyService.mediaSourceID(from: "https://emby.example/Videos/1/stream.mp4?api_key=token&MediaSourceId=source-a"),
            "source-a"
        )
        XCTAssertEqual(
            EmbyService.mediaSourceID(from: "https://emby.example/Videos/1/stream.mp4?api_key=token&mediasourceid=source-b"),
            "source-b"
        )
        XCTAssertEqual(
            EmbyService.mediaSourceID(from: "https://emby.example/Videos/1/stream.mp4?api_key=token&MEDIASOURCEID=source-c"),
            "source-c"
        )
    }

    func testMediaSourceIDPreservesFirstMatchingValueAndIgnoresUnrelatedQueries() {
        XCTAssertEqual(
            EmbyService.mediaSourceID(
                from: "https://emby.example/Videos/1/stream.mp4?MediaSourceID=source-a&MediaSourceId=source-b"
            ),
            "source-a"
        )
        XCTAssertNil(
            EmbyService.mediaSourceID(from: "https://emby.example/Videos/1/stream.mp4?source=source-a")
        )
    }

    func testMediaSourceIDRejectsNilAndMalformedInputs() {
        XCTAssertNil(EmbyService.mediaSourceID(from: nil))
        XCTAssertNil(EmbyService.mediaSourceID(from: "not a url"))
    }
}
