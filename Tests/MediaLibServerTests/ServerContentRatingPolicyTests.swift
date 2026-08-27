import XCTest
@testable import MediaLibServer

final class ServerContentRatingPolicyTests: XCTestCase {
    func testCommonRegionalLabelsAndNumericAgesUseOneFailClosedLadder() {
        XCTAssertTrue(ServerContentRatingPolicy.allows(contentRating: "PG", maximum: "PG-13"))
        XCTAssertTrue(ServerContentRatingPolicy.allows(contentRating: "TV-14", maximum: "16"))
        XCTAssertFalse(ServerContentRatingPolicy.allows(contentRating: "R", maximum: "PG-13"))
        XCTAssertFalse(ServerContentRatingPolicy.allows(contentRating: nil, maximum: "PG-13"))
        XCTAssertFalse(ServerContentRatingPolicy.allows(contentRating: "UNRATED", maximum: "PG-13"))
        XCTAssertFalse(ServerContentRatingPolicy.allows(contentRating: "PG", maximum: "custom-label"))
        XCTAssertTrue(ServerContentRatingPolicy.allows(contentRating: "R", maximum: nil))
    }
}
