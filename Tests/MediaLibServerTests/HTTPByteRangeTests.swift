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

    func testResolvesRangesBeyondFourGiBWithoutNarrowingOrOverflow() {
        let total: Int64 = 8 * 1_024 * 1_024 * 1_024
        let lower: Int64 = 5 * 1_024 * 1_024 * 1_024
        let resolved = HTTPByteRangeRequest(
            headerValue: "bytes=\(lower)-\(lower + 1_023)"
        )?.resolve(totalLength: total)

        XCTAssertEqual(resolved?.lowerBound, lower)
        XCTAssertEqual(resolved?.upperBound, lower + 1_023)
        XCTAssertEqual(resolved?.length, 1_024)
        XCTAssertEqual(
            resolved?.contentRangeHeader,
            "bytes \(lower)-\(lower + 1_023)/\(total)"
        )
        XCTAssertNil(HTTPByteRangeRequest(headerValue: "bytes=9223372036854775808-"))
    }
}
