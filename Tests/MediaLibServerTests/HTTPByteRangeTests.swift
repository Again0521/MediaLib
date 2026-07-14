import XCTest
@testable import MediaLibServer

final class HTTPByteRangeTests: XCTestCase {
    func testClosedRangeClampsAtEndOfFile() {
        let request = HTTPByteRangeRequest(headerValue: "bytes=8-99")

        XCTAssertEqual(
            request?.resolve(totalLength: 10),
            ResolvedHTTPByteRange(lowerBound: 8, upperBound: 9, totalLength: 10)
        )
    }

    func testOpenAndSuffixRangesResolveWithoutNegativeOffsets() {
        XCTAssertEqual(
            HTTPByteRangeRequest(headerValue: "bytes=7-")?.resolve(totalLength: 10),
            ResolvedHTTPByteRange(lowerBound: 7, upperBound: 9, totalLength: 10)
        )
        XCTAssertEqual(
            HTTPByteRangeRequest(headerValue: "bytes=-50")?.resolve(totalLength: 10),
            ResolvedHTTPByteRange(lowerBound: 0, upperBound: 9, totalLength: 10)
        )
    }

    func testRejectsMultiRangeAndMalformedRequests() {
        XCTAssertNil(HTTPByteRangeRequest(headerValue: "bytes=0-1,3-4"))
        XCTAssertNil(HTTPByteRangeRequest(headerValue: "bytes=-0"))
        XCTAssertNil(HTTPByteRangeRequest(headerValue: "items=0-1"))
        XCTAssertNil(HTTPByteRangeRequest(headerValue: "bytes=4-2"))
    }
}
