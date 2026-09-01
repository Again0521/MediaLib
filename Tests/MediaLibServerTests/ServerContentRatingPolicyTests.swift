import XCTest
import MediaLibCore
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

    func testRegionalBoardsAndProviderNamespacesNormalizeWithoutAuthorizingArbitraryNumbers() {
        let expected: [(String, Int)] = [
            ("FSK 12", 12), ("DE:FSK-16", 16), ("BBFC/12A", 12),
            ("AU-MA15+", 15), ("CA 14A", 14), ("FR -16", 16),
            ("EIRIN PG12", 12), ("JP:R15+", 15), ("KMRB-15", 15),
            ("SG:NC16", 16), ("IMDA R21", 21), ("CBFC-UA13+", 13),
            ("BR:L", 0), ("DJCTQ-14", 14), ("NL:KIJKWIJZER-9", 9),
            ("TV-Y7-FV", 7), ("Rated PG-13", 13), ("１８＋", 18)
        ]
        for (label, age) in expected {
            XCTAssertEqual(ServerContentRatingPolicy.age(for: label), age, label)
        }
        for label in ["Season 18", "Episode 12", "2026", "UNRATED", "NR", "custom-label", ""] {
            XCTAssertNil(ServerContentRatingPolicy.age(for: label), label)
        }
    }

    func testUserPolicyRejectsUnknownMaximumButAcceptsNormalizedAge() {
        XCTAssertTrue(ServerUserPolicy(maximumContentRating: "14").isValid)
        XCTAssertTrue(ServerUserPolicy(maximumContentRating: "FSK 12").isValid)
        XCTAssertFalse(ServerUserPolicy(maximumContentRating: "custom-label").isValid)
    }
}
